
#include <stdlib.h>
#include <cuda_runtime.h>
#include <device_launch_parameters.h>
#include <thrust/device_vector.h>
#include <thrust/host_vector.h>
#include <thrust/execution_policy.h>
#include <thrust/for_each.h>
#include <rmm/rmm.h>
#include <rmm/thrust_rmm_allocator.h>
#include "NVStrings.h"
#include "NVStringsImpl.h"
#include "custring_view.cuh"
#include "regex/regex.cuh"
#include "Timing.h"

// Extract character from each component at specified position
NVStrings* NVStrings::get(unsigned int pos)
{
    return slice(pos,pos+1,1);
}


// All strings are substr'd with the same (start,stop) position values.
NVStrings* NVStrings::slice( int start, int stop, int step )
{
    if( (stop > 0) && (start > stop) )
        return 0;

    auto execpol = rmm::exec_policy(0);
    unsigned int count = size();
    custring_view_array d_strings = pImpl->getStringsPtr();
    // compute size of output buffer
    rmm::device_vector<size_t> lengths(count,0);
    size_t* d_lengths = lengths.data().get();
    double st1 = GetTime();
    thrust::for_each_n(execpol->on(0), thrust::make_counting_iterator<unsigned int>(0), count,
        [d_strings, start, stop, step, d_lengths] __device__(unsigned int idx){
            custring_view* dstr = d_strings[idx];
            if( !dstr )
                return;
            int len = ( stop <= 0 ? dstr->chars_count() : stop ) - start;
            unsigned int size = dstr->substr_size((unsigned)start,(unsigned)len,(unsigned)step);
            size = ALIGN_SIZE(size);
            d_lengths[idx] = (size_t)size;
        });
    // create output object
    NVStrings* rtn = new NVStrings(count);
    char* d_buffer = rtn->pImpl->createMemoryFor(d_lengths);
    if( d_buffer==0 )
        return rtn;
    double et1 = GetTime();
    // create offsets
    rmm::device_vector<size_t> offsets(count,0);
    thrust::exclusive_scan(execpol->on(0),lengths.begin(),lengths.end(),offsets.begin());
    // slice it and dice it
    custring_view_array d_results = rtn->pImpl->getStringsPtr();
    size_t* d_offsets = offsets.data().get();
    double st2 = GetTime();
    thrust::for_each_n(execpol->on(0), thrust::make_counting_iterator<unsigned int>(0), count,
        [d_strings, start, stop, step, d_buffer, d_offsets, d_results] __device__(unsigned int idx){
            custring_view* dstr = d_strings[idx];
            if( !dstr )
                return;
            char* buffer = d_buffer + d_offsets[idx];
            int len = ( stop <= 0 ? dstr->chars_count() : stop ) - start;
            d_results[idx] = dstr->substr((unsigned)start,(unsigned)len,(unsigned)step,buffer);
        });
    //
    cudaError_t err = cudaDeviceSynchronize();
    double et2 = GetTime();
    if( err != cudaSuccess )
    {
        fprintf(stderr,"nvs-slice(%d,%d,%d)\n",start,stop,step);
        printCudaError(err);
    }
    pImpl->addOpTimes("slice",(et1-st1),(et2-st2));
    return rtn;
}

// Each string is substr'd according to the individual (start,stop) position values
NVStrings* NVStrings::slice_from( int* starts, int* stops )
{
    unsigned int count = size();
    custring_view_array d_strings = pImpl->getStringsPtr();
    auto execpol = rmm::exec_policy(0);
    // compute size of output buffer
    rmm::device_vector<size_t> lengths(count,0);
    size_t* d_lengths = lengths.data().get();
    double st1 = GetTime();
    thrust::for_each_n(execpol->on(0), thrust::make_counting_iterator<unsigned int>(0), count,
        [d_strings, starts, stops, d_lengths] __device__(unsigned int idx){
            custring_view* dstr = d_strings[idx];
            if( !dstr )
                return;
            int start = (starts ? starts[idx]:0);
            int stop = (stops ? stops[idx]: -1);
            int len = ( stop <= 0 ? dstr->chars_count() : stop ) - start;
            unsigned int size = dstr->substr_size((unsigned)start,(unsigned)len);
            size = ALIGN_SIZE(size);
            d_lengths[idx] = (size_t)size;
        });
    // create output object
    NVStrings* rtn = new NVStrings(count);
    char* d_buffer = rtn->pImpl->createMemoryFor(d_lengths);
    if( d_buffer==0 )
        return rtn;
    double et1 = GetTime();
    // create offsets
    rmm::device_vector<size_t> offsets(count,0);
    thrust::exclusive_scan(execpol->on(0),lengths.begin(),lengths.end(),offsets.begin());
    // slice, slice, baby
    custring_view_array d_results = rtn->pImpl->getStringsPtr();
    size_t* d_offsets = offsets.data().get();
    double st2 = GetTime();
    thrust::for_each_n(execpol->on(0), thrust::make_counting_iterator<unsigned int>(0), count,
        [d_strings, starts, stops, d_buffer, d_offsets, d_results] __device__(unsigned int idx){
            custring_view* dstr = d_strings[idx];
            if( !dstr )
                return;
            int start = (starts ? starts[idx]:0);
            int stop = (stops ? stops[idx]: -1);
            char* buffer = d_buffer + d_offsets[idx];
            int len = ( stop <= 0 ? dstr->chars_count() : stop ) - start;
            d_results[idx] = dstr->substr((unsigned)start,(unsigned)len,1,buffer);
        });
    //
    cudaError_t err = cudaDeviceSynchronize();
    double et2 = GetTime();
    if( err != cudaSuccess )
    {
        fprintf(stderr,"nvs-slice_from(%p,%p)\n",starts,stops);
        printCudaError(err);
    }
    pImpl->addOpTimes("slice",(et1-st1),(et2-st2));
    return rtn;
}

//
int NVStrings::extract_record( const char* pattern, std::vector<NVStrings*>& results)
{
    if( pattern==0 )
        return -1;
    unsigned int count = size();
    if( count==0 )
        return 0;

    auto execpol = rmm::exec_policy(0);
    // compile regex into device object
    const char32_t* ptn32 = to_char32(pattern);
    dreprog* prog = dreprog::create_from(ptn32,get_unicode_flags(),count);
    delete ptn32;
    //
    int groups = prog->group_counts();
    if( groups==0 )
    {
        dreprog::destroy(prog);
        return 0;
    }
    // compute lengths of each group for each string
    custring_view_array d_strings = pImpl->getStringsPtr();
    rmm::device_vector<int> lengths(count*groups,0);
    int* d_lengths = lengths.data().get();
    thrust::for_each_n(execpol->on(0), thrust::make_counting_iterator<unsigned int>(0), count,
        [prog, d_strings, groups, d_lengths] __device__(unsigned int idx){
            custring_view* dstr = d_strings[idx];
            if( !dstr )
                return;
            int begin = 0, end = dstr->chars_count();
            if( prog->find(idx,dstr,begin,end) <=0 )
                return;
            int* sizes = d_lengths + (idx*groups);
            for( int col=0; col < groups; ++col )
            {
                int spos=begin, epos=end;
                if( prog->extract(idx,dstr,spos,epos,col) <=0 )
                    continue;
                unsigned int size = dstr->substr_size(spos,epos); // this is wrong
                sizes[col] = (size_t)ALIGN_SIZE(size);
            }
        });
    //
    cudaDeviceSynchronize();
    // this part will be slow for large number of strings
    rmm::device_vector<custring_view_array> strings(count,nullptr);
    rmm::device_vector<char*> buffers(count,nullptr);
    for( unsigned int idx=0; idx < count; ++idx )
    {
        NVStrings* row = new NVStrings(groups);
        results.push_back(row);
        int* sizes = d_lengths + (idx*groups);
        int size = thrust::reduce(execpol->on(0), sizes, sizes+groups);
        if( size==0 )
            continue;
        char* d_buffer = 0;
        RMM_ALLOC(&d_buffer,size,0);
        row->pImpl->setMemoryBuffer(d_buffer,size);
        strings[idx] = row->pImpl->getStringsPtr();
        buffers[idx] = d_buffer;
    }
    // copy each subgroup into each rows memory
    custring_view_array* d_rows = strings.data().get();
    char** d_buffers = buffers.data().get();
    thrust::for_each_n(execpol->on(0), thrust::make_counting_iterator<unsigned int>(0), count,
        [prog, d_strings, d_buffers, d_lengths, groups, d_rows] __device__(unsigned int idx){
            custring_view* dstr = d_strings[idx];
            if( !dstr )
                return;
            int begin = 0, end = dstr->chars_count(); // these could have been saved above
            if( prog->find(idx,dstr,begin,end) <=0 )      // to avoid this call again here
                return;
            int* sizes = d_lengths + (idx*groups);
            char* buffer = (char*)d_buffers[idx];
            custring_view_array d_row = d_rows[idx];
            for( int col=0; col < groups; ++col )
            {
                int spos=begin, epos=end;
                if( prog->extract(idx,dstr,spos,epos,col) <=0 )
                    continue;
                d_row[col] = dstr->substr((unsigned)spos,(unsigned)(epos-spos),1,buffer);
                buffer += sizes[col];
            }
        });
        //
    cudaError_t err = cudaDeviceSynchronize();
    if( err != cudaSuccess )
    {
        fprintf(stderr,"nvs-extract_record(%s): groups=%d\n",pattern,groups);
        printCudaError(err);
    }
    dreprog::destroy(prog);
    return groups;
}

// column-major version of extract() method above
int NVStrings::extract( const char* pattern, std::vector<NVStrings*>& results)
{
    if( pattern==0 )
        return -1;
    unsigned int count = size();
    if( count==0 )
        return 0;

    auto execpol = rmm::exec_policy(0);
    // compile regex into device object
    const char32_t* ptn32 = to_char32(pattern);
    dreprog* prog = dreprog::create_from(ptn32,get_unicode_flags(),count);
    delete ptn32;
    //
    int groups = prog->group_counts();
    if( groups==0 )
    {
        dreprog::destroy(prog);
        return 0;
    }
    //
    custring_view_array d_strings = pImpl->getStringsPtr();
    rmm::device_vector<int> begins(count,0);
    int* d_begins = begins.data().get();
    rmm::device_vector<int> ends(count,0);
    int* d_ends = ends.data().get();
    rmm::device_vector<size_t> lengths(count,0);
    size_t* d_lengths = lengths.data().get();
    // build strings vector for each group (column)
    for( int col=0; col < groups; ++col )
    {
        // first, build two vectors of (begin,end) position values;
        // also get the lengths of the substrings
        thrust::for_each_n(execpol->on(0), thrust::make_counting_iterator<unsigned int>(0), count,
            [prog, d_strings, col, d_begins, d_ends, d_lengths] __device__(unsigned int idx) {
                custring_view* dstr = d_strings[idx];
                d_begins[idx] = -1;
                d_ends[idx] = -1;
                if( !dstr )
                    return;
                int begin=0, end=dstr->chars_count();
                int result = prog->find(idx,dstr,begin,end);
                if( result > 0 )
                    result = prog->extract(idx,dstr,begin,end,col);
                if( result > 0 )
                {
                    d_begins[idx] = begin;
                    d_ends[idx] = end;
                    unsigned int size = dstr->substr_size(begin,end-begin);
                    d_lengths[idx] = (size_t)ALIGN_SIZE(size);
                }
            });
        cudaDeviceSynchronize();
        // create list of strings for this group
        NVStrings* column = new NVStrings(count);
        results.push_back(column); // append here so continue statement will work
        char* d_buffer = column->pImpl->createMemoryFor(d_lengths);
        if( d_buffer==0 )
            continue;
        rmm::device_vector<size_t> offsets(count,0);
        thrust::exclusive_scan(execpol->on(0),lengths.begin(),lengths.end(),offsets.begin());
        // copy the substrings into the new object
        custring_view_array d_results = column->pImpl->getStringsPtr();
        size_t* d_offsets = offsets.data().get();
        thrust::for_each_n(execpol->on(0), thrust::make_counting_iterator<unsigned int>(0), count,
            [d_strings, d_begins, d_ends, d_buffer, d_offsets, d_results] __device__(unsigned int idx){
                custring_view* dstr = d_strings[idx];
                if( !dstr )
                    return;
                int start = d_begins[idx];
                int stop = d_ends[idx];
                if( stop > start )
                    d_results[idx] = dstr->substr((unsigned)start,(unsigned)(stop-start),1,d_buffer+d_offsets[idx]);
            });
        //
        cudaError_t err = cudaDeviceSynchronize();
        if( err != cudaSuccess )
        {
            fprintf(stderr,"nvs-extract(%s): col=%d\n",pattern,col);
            printCudaError(err);
        }
        // column already added to results above
    }
    dreprog::destroy(prog);
    return groups;
}

