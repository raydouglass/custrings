
// internal declarations for regex compilier and executor
#include <string>
#include <vector>

/*
* Actions and Tokens (Reinst types)
*	02xx are operators, value == precedence
*	03xx are tokens, i.e. operands for operators
*/
enum InstType
{
    CHAR = 0177,
    RBRA = 0201, /* Right bracket, ) */
    LBRA = 0202, /* Left bracket, ( */
    OR = 0204, /* Alternation, | */
    ANY = 0300, /* Any character except newline, . */
    ANYNL = 0301, /* Any character including newline, . */
    BOL = 0303, /* Beginning of line, ^ */
    EOL = 0304, /* End of line, $ */
    CCLASS = 0305, /* Character class, [] */
    NCCLASS = 0306, /* Negated character class, [] */
    BOW = 0307, /* Boundary of word, /b */
    NBOW = 0310, /* Not boundary of word, /b */
    END = 0377 /* Terminate: match found */
};

//typedef std::u32string Reclass; // .length should be multiple of 2
struct Reclass
{
    int builtins;        // bit mask identifying builtin classes
    std::u32string chrs; // ranges as pairs of chars
    Reclass() : builtins(0) {}
    Reclass(int m) : builtins(m) {}
};

struct Reinst
{
    int	type;
    union	{
        int	cls_id;		/* class pointer */
        char32_t	c;		/* character */
        int	subid;		/* sub-expression id for RBRA and LBRA */
        int	right_id;		/* right child of OR */
    } u1;
    union {	/* regexp relies on these two being in the same union */
        int left_id;		/* left child of OR */
        int next_id;		/* next instruction for CAT & LBRA */
    } u2;
    int pad4; // extra 4 bytes to make this align on 8-byte boundary
};

//
class Reprog
{
    std::vector<Reinst> insts;
    std::vector<Reclass> classes;
    int startinst_id;
    int num_capturing_groups;

public:

    static Reprog* create_from(const char32_t* pattern);

    int add_inst(int type);
    int add_inst(Reinst inst);
    int add_class(Reclass cls);

    int inst_count() const;
    int classes_count() const;
    void set_groups_count(int groups);
    int groups_count() const;

    const Reinst* insts_data() const;

    Reinst& inst_at(int id);
    Reclass& class_at(int id);

    void set_start_inst(int id);
    int get_start_inst() const;

    void optimize();
    void print(); // for debugging
};

