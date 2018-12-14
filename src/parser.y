/*
**      cdecl -- C gibberish translator
**      src/parser.y
**
**      Copyright (C) 2017  Paul J. Lucas, et al.
**
**      This program is free software: you can redistribute it and/or modify
**      it under the terms of the GNU General Public License as published by
**      the Free Software Foundation, either version 3 of the License, or
**      (at your option) any later version.
**
**      This program is distributed in the hope that it will be useful,
**      but WITHOUT ANY WARRANTY; without even the implied warranty of
**      MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
**      GNU General Public License for more details.
**
**      You should have received a copy of the GNU General Public License
**      along with this program.  If not, see <http://www.gnu.org/licenses/>.
*/

/**
 * @file
 * Defines helper macros, data structures, variables, functions, and the
 * grammar for C/C++ declarations.
 */

/** @cond DOXYGEN_IGNORE */

%expect 24

%{
/** @endcond */

// local
#include "cdecl.h"                      /* must come first */
#include "c_ast.h"
#include "c_ast_util.h"
#include "c_keyword.h"
#include "c_lang.h"
#include "c_operator.h"
#include "c_type.h"
#include "c_typedef.h"
#include "color.h"
#ifdef ENABLE_CDECL_DEBUG
#include "debug.h"
#endif /* ENABLE_CDECL_DEBUG */
#include "lexer.h"
#include "literals.h"
#include "options.h"
#include "print.h"
#include "slist.h"
#include "typedefs.h"
#include "util.h"

/// @cond DOXYGEN_IGNORE

// standard
#include <assert.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>

/// @endcond

///////////////////////////////////////////////////////////////////////////////

/// @cond DOXYGEN_IGNORE

#ifdef ENABLE_CDECL_DEBUG
#define IF_DEBUG(...)             BLOCK( if ( opt_debug ) { __VA_ARGS__ } )
#else
#define IF_DEBUG(...)             /* nothing */
#endif /* ENABLE_CDECL_DEBUG */

#define C_AST_CHECK(AST,CHECK) \
  BLOCK( if ( !c_ast_check( (AST), (CHECK) ) ) PARSE_ABORT(); )

#define C_AST_NEW(KIND,LOC) \
  SLIST_APPEND( c_ast_t*, &ast_gc_list, c_ast_new( (KIND), ast_depth, (LOC) ) )

#define C_TYPE_ADD(DST,SRC,LOC) \
  BLOCK( if ( !c_type_add( (DST), (SRC), &(LOC) ) ) PARSE_ABORT(); )

// Developer aid for tracing when Bison %destructors are called.
#if 0
#define DTRACE                    PRINT_ERR( "%d: destructor\n", __LINE__ )
#else
#define DTRACE                    NO_OP
#endif

#define DUMP_COMMA \
  BLOCK( if ( true_or_set( &debug_comma ) ) PUTS_OUT( ",\n" ); )

#define DUMP_AST(KEY,AST) \
  IF_DEBUG( DUMP_COMMA; c_ast_debug( (AST), 1, (KEY), stdout ); )

#define DUMP_AST_LIST(KEY,AST_LIST) IF_DEBUG( \
  DUMP_COMMA; printf( "  %s = ", (KEY) );     \
  c_ast_list_debug( &(AST_LIST), 1, stdout ); )

#define DUMP_LITERAL(KEY,NAME)    DUMP_NAME(KEY,NAME)

#define DUMP_NAME(KEY,NAME) IF_DEBUG( \
  DUMP_COMMA; PUTS_OUT( "  " );       \
  print_kv( (KEY), (NAME), stdout ); )

#define DUMP_NUM(KEY,NUM) \
  IF_DEBUG( DUMP_COMMA; printf( "  " KEY " = %d", (NUM) ); )

#ifdef ENABLE_CDECL_DEBUG
#define DUMP_START(NAME,PROD) \
  bool debug_comma = false;   \
  IF_DEBUG( PUTS_OUT( "\n" NAME " ::= " PROD " = {\n" ); )
#else
#define DUMP_START(NAME,PROD)     /* nothing */
#endif

#define DUMP_END()                IF_DEBUG( PUTS_OUT( "\n}\n" ); )

#define DUMP_TYPE(KEY,TYPE) IF_DEBUG( \
  DUMP_COMMA; printf( "  %s = ", (KEY) ); c_type_debug( TYPE, stdout ); )

#define ELABORATE_ERROR(...) \
  BLOCK( elaborate_error( __VA_ARGS__ ); PARSE_ABORT(); )

#define PARSE_ABORT()             BLOCK( parse_cleanup( true ); YYABORT; )

#define SHOW_ALL_TYPES            (~0u)
#define SHOW_PREDEFINED_TYPES     0x01u
#define SHOW_USER_TYPES           0x02u

/// @endcond

///////////////////////////////////////////////////////////////////////////////

/**
 * Print type function signature for print_type_visitor().
 */
typedef void (*print_type_t)( c_typedef_t const* );

/**
 * Information for print_type_visitor().
 */
struct print_type_info {
  print_type_t  print_fn;               ///< Print English or gibberish?
  unsigned      show_which;             ///< Predefined, user, or both?
};
typedef struct print_type_info print_type_info_t;

/**
 * Qualifier and its source location.
 */
struct c_qualifier {
  c_type_id_t type_id;                  ///< E.g., `T_CONST` or `T_VOLATILE`.
  c_loc_t     loc;                      ///< Qualifier source location.
};
typedef struct c_qualifier c_qualifier_t;

/**
 * Inherited attributes.
 */
struct in_attr {
  slist_t qualifier_stack;              ///< Qualifier stack.
  slist_t type_stack;                   ///< Type stack.
};
typedef struct in_attr in_attr_t;

// extern functions
extern char const*    c_graph_name( char const* );
extern void           print_help( void );
extern void           set_option( char const* );
extern int            yylex( void );

// local variables
static c_ast_depth_t  ast_depth;        ///< Parentheses nesting depth.
static slist_t        ast_gc_list;      ///< `c_ast` nodes freed after parse.
static slist_t        ast_typedef_list; ///< `c_ast` nodes for `typedef`s.
static bool           error_newlined = true;
static in_attr_t      in_attr;          ///< Inherited attributes.

////////// inline functions ///////////////////////////////////////////////////

/**
 * Gets a printable string of the lexer's current token.
 *
 * @return Returns said string.
 */
static inline char const* printable_token( void ) {
  return lexer_token[0] == '\n' ? "\\n" : lexer_token;
}

/**
 * Peeks at the type `c_ast` at the top of the type AST inherited attribute
 * stack.
 *
 * @return Returns said `c_ast`.
 */
static inline c_ast_t* type_peek( void ) {
  return SLIST_TOP( c_ast_t*, &in_attr.type_stack );
}

/**
 * Pops a type `c_ast` from the type AST inherited attribute stack.
 *
 * @return Returns said `c_ast`.
 */
static inline c_ast_t* type_pop( void ) {
  return SLIST_POP( c_ast_t*, &in_attr.type_stack );
}

/**
 * Pushes a type `c_ast` onto the type AST inherited attribute stack.
 *
 * @param ast The `c_ast` to push.
 */
static inline void type_push( c_ast_t *ast ) {
  slist_push( &in_attr.type_stack, ast );
}

/**
 * Peeks at the qualifier at the top of the qualifier inherited attribute
 * stack.
 *
 * @return Returns said qualifier.
 */
static inline c_type_id_t qualifier_peek( void ) {
  return SLIST_TOP( c_qualifier_t*, &in_attr.qualifier_stack )->type_id;
}

/**
 * Peeks at the location of the qualifier at the top of the qualifier inherited
 * attribute stack.
 *
 * @note This is a macro instead of an inline function because it should return
 * a reference (not a pointer), but C doesn't have references.
 *
 * @return Returns said qualifier location.
 * @hideinitializer
 */
#define qualifier_peek_loc() \
  (SLIST_TOP( c_qualifier_t*, &in_attr.qualifier_stack )->loc)

/**
 * Pops a qualifier from the qualifier inherited attribute stack and frees it.
 */
static inline void qualifier_pop( void ) {
  FREE( slist_pop( &in_attr.qualifier_stack ) );
}

////////// extern functions ///////////////////////////////////////////////////

/**
 * Cleans up parser data at program termination.
 */
void parser_cleanup( void ) {
  slist_free( &ast_typedef_list, (slist_data_free_fn_t)&c_ast_free );
}

////////// local functions ////////////////////////////////////////////////////

/**
 * Prints an additional parsing error message to standard error that continues
 * from where `yyerror()` left off.
 *
 * @param format A `printf()` style format string.
 */
static void elaborate_error( char const *format, ... ) {
  if ( !error_newlined ) {
    PUTS_ERR( ": " );
    if ( lexer_token[0] != '\0' )
      PRINT_ERR( "\"%s\": ", printable_token() );
    va_list args;
    va_start( args, format );
    vfprintf( stderr, format, args );
    va_end( args );
    PUTC_ERR( '\n' );
    error_newlined = true;
  }
}

/**
 * Checks whether the `_Noreturn` token is OK in the current language.  If not,
 * prints an error message (and perhaps a hint).
 *
 * @param loc The location of the `_Noreturn` token.
 * @return Returns `true` only of `_Noreturn` is OK.
 */
static bool _Noreturn_ok( c_loc_t const *loc ) {
  if ( (opt_lang & LANG_C_MIN(11)) != LANG_NONE )
    return true;
  print_error( loc, "\"%s\" not supported in %s", lexer_token, C_LANG_NAME() );
  if ( opt_lang >= LANG_CPP_11 ) {
    if ( c_mode == MODE_ENGLISH_TO_GIBBERISH )
      print_hint( "\"%s\"", L_NORETURN );
    else
      print_hint( "[[%s]]", L_NORETURN );
  }
  return false;
}

/**
 * Cleans-up parser data after each parse.
 *
 * @param hard_reset If `true`, does a "hard" reset that currently resets the
 * EOF flag of the lexer.  This should be `true` if an error occurs and
 * `YYABORT` is called.
 */
static void parse_cleanup( bool hard_reset ) {
  lexer_reset( hard_reset );
  slist_free( &ast_gc_list, (slist_data_free_fn_t)&c_ast_free );
  slist_free( &in_attr.qualifier_stack, &free );
  slist_free( &in_attr.type_stack, NULL );
  STRUCT_ZERO( &in_attr );
}

/**
 * Gets ready to parse a command.
 */
static void parse_init( void ) {
  if ( !error_newlined ) {
    FPUTC( '\n', fout );
    error_newlined = true;
  }
}

/**
 * Prints a `c_typedef` in English.
 *
 * @param type A pointer to the `c_typedef` to print.
 */
static void print_type_english( c_typedef_t const *type ) {
  assert( type != NULL );
  FPRINTF( fout, "%s %s %s ", L_DEFINE, type->ast->name, L_AS );
  c_ast_english( type->ast, fout );
  FPUTC( '\n', fout );
}

/**
 * Prints a `c_typedef` in gibberish.
 *
 * @param type A pointer to the `c_typedef` to print.
 */
static void print_type_gibberish( c_typedef_t const *type ) {
  assert( type != NULL );
  FPRINTF( fout, "%s ", L_TYPEDEF );
  c_ast_gibberish_declare( type->ast, fout );
  if ( opt_semicolon )
    FPUTC( ';', fout );
  FPUTC( '\n', fout );
}

/**
 * Prints the definition of a `typedef`.
 *
 * @param type A pointer to the `c_typedef` to print.
 * @param data Optional data passed to the visitor: in this case, the bitmask
 * of which `typedef`s to print.
 * @return Always returns `false`.
 */
static bool print_type_visitor( c_typedef_t const *type, void *data ) {
  assert( type != NULL );

  print_type_info_t const *const pti =
    REINTERPRET_CAST( print_type_info_t const*, data );

  bool const show_it = type->user_defined ?
    (pti->show_which & SHOW_USER_TYPES) != 0 :
    (pti->show_which & SHOW_PREDEFINED_TYPES) != 0;

  if ( show_it )
    (*pti->print_fn)( type );
  return false;
}

/**
 * Pushes a qualifier onto the qualifier inherited attribute stack.
 *
 * @param qualifier The qualifier to push.
 * @param loc A pointer to the source location of the qualifier.
 */
static void qualifier_push( c_type_id_t qualifier, c_loc_t const *loc ) {
  assert( (qualifier & ~T_MASK_QUALIFIER) == 0 );
  assert( loc != NULL );

  c_qualifier_t *const qual = MALLOC( c_qualifier_t, 1 );
  qual->type_id = qualifier;
  qual->loc = *loc;
  slist_push( &in_attr.qualifier_stack, qual );
}

/**
 * Implements the cdecl `quit` command.
 */
static void quit( void ) {
  exit( EX_OK );
}

/**
 * Prints a parsing error message to standard error.  This function is called
 * directly by Bison to print just `syntax error` (usually).
 *
 * @note A newline is \e not printed since the error message will be appended
 * to by `elaborate_error()`.  For example, the parts of an error message are
 * printed by the functions shown:
 *
 *      42: syntax error: "int": "into" expected
 *      |--||----------||----------------------|
 *      |   |           |
 *      |   yyerror()   elaborate_error()
 *      |
 *      print_loc()
 *
 * @param msg The error message to print.
 */
static void yyerror( char const *msg ) {
  c_loc_t loc;
  STRUCT_ZERO( &loc );
  lexer_loc( &loc.first_line, &loc.first_column );
  print_loc( &loc );

  SGR_START_COLOR( stderr, error );
  PUTS_ERR( msg );                      // no newline
  SGR_END_COLOR( stderr );
  error_newlined = false;

  parse_cleanup( false );
}

///////////////////////////////////////////////////////////////////////////////

/// @cond DOXYGEN_IGNORE

%}

%union {
  c_ast_t            *ast;
  slist_t             ast_list;   /* for function arguments */
  c_ast_pair_t        ast_pair;   /* for the AST being built */
  unsigned            bitmask;    /* multipurpose bitmask (used by show) */
  char const         *literal;    /* token literal (for new-style casts) */
  char const         *name;       /* name being declared or explained */
  int                 number;     /* for array sizes */
  c_oper_id_t         oper_id;    /* overloaded operator ID */
  c_type_id_t         type_id;    /* built-ins, storage classes, & qualifiers */
  c_typedef_t const  *c_typedef;  /* typedef type */
}

                    /* commands */
%token              Y_CAST
%token              Y_DECLARE
%token              Y_DEFINE
%token              Y_EXPLAIN
%token              Y_HELP
%token              Y_SET
%token              Y_SHOW
%token              Y_QUIT

                    /* english */
%token              Y_ALL
%token              Y_ARRAY
%token              Y_AS
%token              Y_BLOCK             /* Apple: English for '^' */
%token              Y_DYNAMIC
%token              Y_FUNCTION
%token              Y_INTO
%token              Y_LENGTH
%token              Y_MEMBER
%token              Y_NON_MEMBER
%token              Y_OF
%token              Y_POINTER
%token              Y_PREDEFINED
%token              Y_PURE
%token              Y_REFERENCE
%token              Y_REINTERPRET
%token              Y_RETURNING
%token              Y_RVALUE
%token              Y_TO
%token              Y_TYPES
%token              Y_USER
%token              Y_VARIABLE

                    /* K&R C */
%token  <oper_id>   '!'
%token  <oper_id>   '%'
%token  <oper_id>   '&'
%token  <oper_id>   '(' ')'
%token  <oper_id>   '*'
%token  <oper_id>   '+'
%token  <oper_id>   ','
%token  <oper_id>   '-'
%token  <oper_id>   '.'
%token  <oper_id>   '/'
%token  <oper_id>   '<' '>'
%token  <oper_id>   '='
%token  <oper_id>   Y_QMARK_COLON "?:"
%token  <oper_id>   '[' ']'
%token  <oper_id>   '^'
%token  <oper_id>   '|'
%token  <oper_id>   '~'
%token  <oper_id>   Y_NOT_EQ      "!="
%token  <oper_id>   Y_PERCENT_EQ  "%="
%token  <oper_id>   Y_AMPER2      "&&"
%token  <oper_id>   Y_AMPER_EQ    "&="
%token  <oper_id>   Y_STAR_EQ     "*="
%token  <oper_id>   Y_PLUS2       "++"
%token  <oper_id>   Y_PLUS_EQ     "+="
%token  <oper_id>   Y_MINUS2      "--"
%token  <oper_id>   Y_MINUS_EQ    "-="
%token  <oper_id>   Y_ARROW       "->"
%token  <oper_id>   Y_SLASH_EQ    "/="
%token  <oper_id>   Y_LESS2       "<<"
%token  <oper_id>   Y_LESS2_EQ    "<<="
%token  <oper_id>   Y_LESS_EQ     "<="
%token  <oper_id>   Y_EQ2         "=="
%token  <oper_id>   Y_GREATER_EQ  ">="
%token  <oper_id>   Y_GREATER2    ">>"
%token  <oper_id>   Y_GREATER2_EQ ">>="
%token  <oper_id>   Y_CIRC_EQ     "^="
%token  <oper_id>   Y_PIPE_EQ     "|="
%token  <oper_id>   Y_PIPE2       "||"
%token  <type_id>   Y_AUTO_C            /* C version of "auto" */
%token              Y_BREAK
%token              Y_CASE
%token  <type_id>   Y_CHAR
%token              Y_CONTINUE
%token              Y_DEFAULT
%token              Y_DO
%token  <type_id>   Y_DOUBLE
%token              Y_ELSE
%token  <type_id>   Y_EXTERN
%token  <type_id>   Y_FLOAT
%token              Y_FOR
%token              Y_GOTO
%token              Y_IF
%token  <type_id>   Y_INT
%token  <type_id>   Y_LONG
%token  <type_id>   Y_REGISTER
%token              Y_RETURN
%token  <type_id>   Y_SHORT
%token  <type_id>   Y_SIZEOF
%token  <type_id>   Y_STATIC
%token  <type_id>   Y_STRUCT
%token              Y_SWITCH
%token  <type_id>   Y_TYPEDEF
%token  <type_id>   Y_UNION
%token  <type_id>   Y_UNSIGNED
%token              Y_WHILE

                    /* C89 */
%token  <type_id>   Y_CONST
%token              Y_ELLIPSIS    "..." /* for varargs */
%token  <type_id>   Y_ENUM
%token  <type_id>   Y_SIGNED
%token  <type_id>   Y_VOID
%token  <type_id>   Y_VOLATILE

                    /* C95 */
%token  <type_id>   Y_WCHAR_T

                    /* C99 */
%token  <type_id>   Y_BOOL
%token  <type_id>   Y__COMPLEX
%token  <type_id>   Y__IMAGINARY
%token  <type_id>   Y_INLINE
%token  <type_id>   Y_RESTRICT

                    /* C11 */
%token              Y__ALIGNAS
%token              Y__ALIGNOF
%token  <type_id>   Y_ATOMIC_QUAL       /* qualifier: _Atomic type */
%token  <type_id>   Y_ATOMIC_SPEC       /* specifier: _Atomic (type) */
%token              Y__GENERIC
%token  <type_id>   Y__NORETURN
%token              Y__STATIC_ASSERT

                    /* C++ */
%token              Y_AND
%token              Y_AND_EQ
%token  <oper_id>   Y_ARROW_STAR  "->*"
%token              Y_BITAND
%token              Y_BITOR
%token              Y_CATCH
%token  <type_id>   Y_CLASS
%token  <oper_id>   Y_COLON2      "::"
%token              Y_COMPL
%token  <literal>   Y_CONST_CAST
%token  <type_id>   Y_DELETE
%token  <oper_id>   Y_DOT_STAR    ".*"
%token  <literal>   Y_DYNAMIC_CAST
%token              Y_EXPLICIT
%token              Y_EXPORT
%token  <type_id>   Y_FALSE             /* for noexcept(false) */
%token  <type_id>   Y_FRIEND
%token  <type_id>   Y_MUTABLE
%token              Y_NAMESPACE
%token  <type_id>   Y_NEW
%token              Y_NOT
%token              Y_OPERATOR
%token              Y_OR
%token              Y_OR_EQ
%token              Y_PRIVATE
%token              Y_PROTECTED
%token              Y_PUBLIC
%token  <literal>   Y_REINTERPRET_CAST
%token  <literal>   Y_STATIC_CAST
%token              Y_TEMPLATE
%token              Y_THIS
%token  <type_id>   Y_THROW
%token  <type_id>   Y_TRUE              /* for noexcept(true) */
%token              Y_TRY
%token              Y_TYPEID
%token              Y_TYPENAME
%token  <type_id>   Y_USING
%token  <type_id>   Y_VIRTUAL
%token              Y_XOR
%token              Y_XOR_EQ

                    /* C++11 */
%token              Y_LBRACKET2   "[["  /* for attribute specifiers */
%token              Y_RBRACKET2   "]]"  /* for attribute specifiers */
%token              Y_ALIGNAS
%token              Y_ALIGNOF
%token  <type_id>   Y_AUTO_CPP_11       /* C++11 version of "auto" */
%token  <type_id>   Y_CARRIES_DEPENDENCY
%token  <type_id>   Y_CONSTEXPR
%token              Y_DECLTYPE
%token  <type_id>   Y_FINAL
%token  <type_id>   Y_NOEXCEPT
%token              Y_NULLPTR
%token  <type_id>   Y_OVERRIDE

                    /* C11 & C++11 */
%token  <type_id>   Y_CHAR16_T
%token  <type_id>   Y_CHAR32_T
%token  <type_id>   Y_THREAD_LOCAL

                    /* C++14 */
%token  <type_id>   Y_DEPRECATED

                    /* C++17 */
%token  <type_id>   Y_MAYBE_UNUSED
%token  <type_id>   Y_NORETURN
%token  <type_id>   Y_NODISCARD

                    /* C++20 */
%token  <oper_id>   Y_LESS_EQ_GREATER "<=>"
%token              Y_CONCEPT
%token  <type_id>   Y_CONSTEVAL
%token              Y_REQUIRES

                    /* miscellaneous */
%token  <type_id>   Y___BLOCK           /* Apple: block storage class */
%token              Y_END
%token              Y_ERROR
%token  <name>      Y_LANG_NAME
%token  <name>      Y_NAME
%token  <number>    Y_NUMBER
%token  <c_typedef> Y_TYPEDEF_TYPE

%type   <ast_pair>  decl_english
%type   <ast_list>  decl_list_english decl_list_opt_english
%type   <ast_pair>  array_decl_english
%type   <number>    array_size_opt_english
%type   <type_id>   attribute_english
%type   <ast_pair>  block_decl_english
%type   <ast_pair>  func_decl_english
%type   <ast_pair>  oper_decl_english
%type   <ast_list>  paren_decl_list_opt_english
%type   <ast_pair>  pointer_decl_english
%type   <ast_pair>  qualifiable_decl_english
%type   <ast_pair>  qualified_decl_english
%type   <type_id>   ref_qualifier_opt_english
%type   <ast_pair>  reference_decl_english
%type   <ast_pair>  reference_english
%type   <ast_pair>  returning_opt_english
%type   <type_id>   storage_class_english storage_class_list_opt_english
%type   <type_id>   type_attribute_english
%type   <ast_pair>  type_english
%type   <type_id>   type_modifier_english
%type   <type_id>   type_modifier_list_english type_modifier_list_opt_english
%type   <ast_pair>  unmodified_type_english
%type   <ast_pair>  var_decl_english

%type   <ast_pair>  cast_c cast_opt_c cast2_c
%type   <ast_pair>  array_cast_c
%type   <ast_pair>  block_cast_c
%type   <ast_pair>  func_cast_c
%type   <ast_pair>  nested_cast_c
%type   <ast_pair>  pointer_cast_c
%type   <ast_pair>  pointer_to_member_cast_c
%type   <type_id>   pure_virtual_opt_c
%type   <ast_pair>  reference_cast_c

%type   <ast_pair>  decl_c decl2_c
%type   <ast_pair>  array_decl_c
%type   <number>    array_size_c
%type   <ast_pair>  block_decl_c
%type   <ast_pair>  func_decl_c
%type   <type_id>   func_noexcept_opt_c
%type   <type_id>   func_ref_qualifier_opt_c
%type   <ast_pair>  func_trailing_return_type_opt_c
%type   <ast_pair>  name_c
%type   <ast_pair>  nested_decl_c
%type   <ast_pair>  oper_c
%type   <ast_pair>  oper_decl_c
%type   <ast_pair>  pointer_decl_c
%type   <ast_pair>  pointer_to_member_decl_c
%type   <ast_pair>  pointer_to_member_type_c
%type   <ast_pair>  pointer_type_c
%type   <ast_pair>  reference_decl_c
%type   <ast_pair>  reference_type_c
%type   <ast_pair>  unmodified_type_c

%type   <ast_pair>  type_ast_c
%type   <ast_pair>  atomic_specifier_type_ast_c
%type   <ast_pair>  builtin_type_ast_c
%type   <ast_pair>  enum_class_struct_union_type_ast_c
%type   <ast_pair>  name_ast_c
%type   <ast_pair>  name_or_typedef_type_ast_c
%type   <ast_pair>  placeholder_type_ast_c
%type   <ast_pair>  typedef_type_ast_c

%type   <type_id>   attribute_name_c
%type   <type_id>   attribute_name_list_c attribute_name_list_opt_c
%type   <type_id>   attribute_specifier_list_c
%type   <type_id>   builtin_type_c
%type   <type_id>   class_struct_type_c class_struct_type_expected_c
%type   <type_id>   cv_qualifier_c cv_qualifier_list_opt_c
%type   <type_id>   enum_class_struct_union_type_c
%type   <type_id>   func_qualifier_c
%type   <type_id>   func_qualifier_list_opt_c
%type   <type_id>   noexcept_bool
%type   <type_id>   storage_class_c
%type   <type_id>   type_modifier_c
%type   <type_id>   type_modifier_base_c
%type   <type_id>   type_modifier_list_c type_modifier_list_opt_c
%type   <type_id>   type_qualifier_c
%type   <type_id>   type_qualifier_list_c type_qualifier_list_opt_c

%type   <ast_pair>  arg_c
%type   <ast>       arg_array_size_c
%type   <ast_list>  arg_list_c arg_list_opt_c
%type   <oper_id>   c_operator
%type   <bitmask>   member_or_non_member_opt
%type   <name>      name_expected
%type   <name>      name_opt
%type   <literal>   new_style_cast_c new_style_cast_english
%type   <name>      set_option
%type   <bitmask>   show_which_types_opt
%type   <type_id>   static_type_opt
%type   <bitmask>   typedef_opt

/*
 * Bison %destructors.  We don't use the <identifier> syntax because older
 * versions of Bison don't support it.
 *
 * Clean-up of AST nodes is done via garbage collection; see c_ast::gc_next.
 */

/* name */
%destructor { DTRACE; FREE( $$ ); } Y_LANG_NAME
%destructor { DTRACE; FREE( $$ ); } Y_NAME name_expected name_opt
%destructor { DTRACE; FREE( $$ ); } set_option

/*****************************************************************************/
%%

command_list
  : /* empty */
  | command_list { parse_init(); } command
    {
      //
      // We get here only after a successful parse, so a hard reset is not
      // needed.
      //
      parse_cleanup( false );
    }
  ;

command
  : cast_english
  | declare_english
  | define_english
  | explain_declaration_c
  | explain_cast_c
  | explain_new_style_cast_c
  | explain_using_declaration_c
  | help_command
  | set_command
  | show_command
  | typedef_declaration_c
  | using_declaration_c
  | quit_command
  | Y_END                               /* allows for blank lines */
  | error
    {
      if ( lexer_token[0] != '\0' )
        ELABORATE_ERROR( "unexpected token" );
      else
        ELABORATE_ERROR( "unexpected end of command" );
    }
  ;

/*****************************************************************************/
/*  cast                                                                     */
/*****************************************************************************/

cast_english
  : Y_CAST Y_NAME into_expected decl_english Y_END
    {
      DUMP_START( "cast_english", "CAST NAME INTO decl_english" );
      DUMP_NAME( "NAME", $2 );
      DUMP_AST( "decl_english", $4.ast );
      DUMP_END();

      bool const ok = c_ast_check( $4.ast, CHECK_CAST );
      if ( ok ) {
        FPUTC( '(', fout );
        c_ast_gibberish_cast( $4.ast, fout );
        FPRINTF( fout, ")%s\n", $2 );
      }
      FREE( $2 );
      if ( !ok )
        PARSE_ABORT();
    }

  | new_style_cast_english
    cast_expected name_expected into_expected decl_english Y_END
    {
      DUMP_START( "cast_english",
                  "new_style_cast_english CAST NAME INTO decl_english" );
      DUMP_LITERAL( "new_style_cast_english", $1 );
      DUMP_NAME( "NAME", $3 );
      DUMP_AST( "decl_english", $5.ast );
      DUMP_END();

      bool ok = false;
      if ( opt_lang < LANG_CPP_11 ) {
        print_error( &@1, "%s not supported in %s", $1, C_LANG_NAME() );
      }
      else if ( (ok = c_ast_check( $5.ast, CHECK_CAST )) ) {
        FPRINTF( fout, "%s<", $1 );
        c_ast_gibberish_cast( $5.ast, fout );
        FPRINTF( fout, ">(%s)\n", $3 );
      }

      FREE( $3 );
      if ( !ok )
        PARSE_ABORT();
    }

  | Y_CAST decl_english Y_END
    {
      DUMP_START( "cast_english", "CAST decl_english" );
      DUMP_AST( "decl_english", $2.ast );
      DUMP_END();

      C_AST_CHECK( $2.ast, CHECK_CAST );
      FPUTC( '(', fout );
      c_ast_gibberish_cast( $2.ast, fout );
      FPUTS( ")\n", fout );
    }
  ;

new_style_cast_english
  : Y_CONST                       { $$ = L_CONST_CAST;        }
  | Y_DYNAMIC                     { $$ = L_DYNAMIC_CAST;      }
  | Y_REINTERPRET                 { $$ = L_REINTERPRET_CAST;  }
  | Y_STATIC                      { $$ = L_STATIC_CAST;       }
  ;

/*****************************************************************************/
/*  declare                                                                  */
/*****************************************************************************/

declare_english
  : Y_DECLARE Y_NAME as_expected storage_class_list_opt_english
    decl_english Y_END
    {
      if ( $5.ast->kind == K_NAME ) {
        //
        // This checks for a case like:
        //
        //      declare x as y
        //
        // i.e., declaring a variable name as another name (unknown type).
        // This can get this far due to the nature of the C/C++ grammar.
        //
        // This check has to be done now in the parser rather than later in the
        // AST because the name of the AST node needs to be set to the variable
        // name, but the AST node is itself a name and overwriting it would
        // lose information.
        //
        assert( $5.ast->name != NULL );
        print_error( &@5, "\"%s\": unknown type", $5.ast->name );
        FREE( $2 );
        PARSE_ABORT();
      }

      c_ast_set_name( $5.ast, $2 );

      DUMP_START( "declare_english",
                  "DECLARE NAME AS storage_class_list_opt_english "
                  "decl_english" );
      DUMP_NAME( "NAME", $2 );
      DUMP_TYPE( "storage_class_list_opt_english", $4 );

      $5.ast->loc = @2;
      C_TYPE_ADD( &$5.ast->type_id, $4, @4 );
      C_AST_CHECK( $5.ast, CHECK_DECL );

      DUMP_AST( "decl_english", $5.ast );
      DUMP_END();

      c_ast_gibberish_declare( $5.ast, fout );
      if ( opt_semicolon )
        FPUTC( ';', fout );
      FPUTC( '\n', fout );
    }

  | Y_DECLARE c_operator as_expected storage_class_list_opt_english
    oper_decl_english Y_END
    {
      DUMP_START( "declare_english",
                  "DECLARE c_operator AS storage_class_list_opt_english "
                  "oper_decl_english" );
      DUMP_NAME( "c_operator", op_get( $2 )->name );
      DUMP_TYPE( "storage_class_list_opt_english", $4 );

      $5.ast->loc = @2;
      $5.ast->as.oper.oper_id = $2;
      C_TYPE_ADD( &$5.ast->type_id, $4, @4 );

      DUMP_AST( "oper_decl_english", $5.ast );
      DUMP_END();

      C_AST_CHECK( $5.ast, CHECK_DECL );
      c_ast_gibberish_declare( $5.ast, fout );
      if ( opt_semicolon )
        FPUTC( ';', fout );
      FPUTC( '\n', fout );
    }

  | Y_DECLARE error
    {
      if ( C_LANG_IS_CPP() )
        ELABORATE_ERROR( "name or %s expected", L_OPERATOR );
      else
        ELABORATE_ERROR( "name expected" );
    }
  ;

storage_class_list_opt_english
  : /* empty */                   { $$ = T_NONE; }
  | storage_class_list_opt_english storage_class_english
    {
      DUMP_START( "storage_class_list_opt_english",
                  "storage_class_list_opt_english storage_class_english" );
      DUMP_TYPE( "storage_class_list_opt_english", $1 );
      DUMP_TYPE( "storage_class_english", $2 );

      $$ = $1;
      C_TYPE_ADD( &$$, $2, @2 );

      DUMP_TYPE( "storage_class_list_opt_english", $$ );
      DUMP_END();
    }
  ;

storage_class_english
  : attribute_english
  | Y_AUTO_C
  | Y___BLOCK                           /* Apple extension */
  | Y_CONSTEVAL
  | Y_CONSTEXPR
  | Y_EXTERN
  | Y_FINAL
  | Y_FRIEND
  | Y_INLINE
  | Y_MUTABLE
  | Y_NOEXCEPT
  | Y_OVERRIDE
/*| Y_REGISTER */                       /* in type_modifier_list_english */
  | Y_STATIC
  | Y_THREAD_LOCAL
  | Y_THROW
  | Y_TYPEDEF
  | Y_VIRTUAL
  | Y_PURE virtual_expected       { $$ = T_PURE_VIRTUAL | T_VIRTUAL; }
  ;

attribute_english
  : type_attribute_english
  | Y_NORETURN
  | Y__NORETURN
    {
      if ( !_Noreturn_ok( &@1 ) )
        PARSE_ABORT();
    }
  ;

/*****************************************************************************/
/*  define
/*****************************************************************************/

define_english
  : Y_DEFINE name_expected as_expected storage_class_list_opt_english
    decl_english Y_END
    {
      if ( $5.ast->kind == K_NAME ) {   // see comment in declare_english
        assert( $5.ast->name != NULL );
        print_error( &@5, "\"%s\": unknown type", $5.ast->name );
        FREE( $2 );
        PARSE_ABORT();
      }

      DUMP_START( "define_english",
                  "DEFINE NAME AS storage_class_list_opt_english "
                  "decl_english" );
      DUMP_NAME( "NAME", $2 );
      DUMP_TYPE( "storage_class_list_opt_english", $4 );
      DUMP_AST( "decl_english", $5.ast );

      //
      // Explicitly add T_TYPEDEF to prohibit cases like:
      //
      //      define eint as extern int
      //      define rint as register int
      //      define sint as static int
      //      ...
      //
      //  i.e., a defined type with a storage class.
      //
      bool ok = c_type_add( &$5.ast->type_id, T_TYPEDEF, &@4 ) &&
                c_type_add( &$5.ast->type_id, $4, &@4 ) &&
                c_ast_check( $5.ast, CHECK_DECL );

      if ( ok ) {
        // Once the semantic checks pass, remove the T_TYPEDEF.
        (void)c_ast_take_typedef( $5.ast );
        c_ast_set_name( $5.ast, $2 );
        if ( c_typedef_add( $5.ast ) ) {
          //
          // If c_typedef_add() succeeds, we have to move the AST from the
          // ast_gc_list so it won't be garbage collected at the end of the
          // parse to a separate ast_typedef_list that's freed only at program
          // termination.
          //
          slist_append_list( &ast_typedef_list, &ast_gc_list );
        }
        else {
          print_error( &@5,
            "\"%s\": \"%s\" redefinition with different type",
            $2, L_TYPEDEF
          );
          ok = false;
        }
      }

      if ( !ok ) {
        FREE( $2 );
        PARSE_ABORT();
      }

      DUMP_AST( "define_english", $5.ast );
      DUMP_END();
    }

  | Y_DEFINE Y_TYPEDEF_TYPE as_expected storage_class_list_opt_english
    decl_english Y_END
    {
      //
      // This is for a case like:
      //
      //      define int_least32_t as int
      //
      // that is: an existing type followed by a type, i.e., redefining an
      // existing type name.
      //
      DUMP_START( "define_english",
                  "DEFINE TYPEDEF_TYPE AS storage_class_list_opt_english "
                  "decl_english" );
      DUMP_NAME( "type_name", $2->ast->name );
      DUMP_AST( "type_ast", $2->ast );
      DUMP_TYPE( "storage_class_list_opt_english", $4 );
      DUMP_AST( "decl_english", $5.ast );
      DUMP_END();

      // see comment above about T_TYPEDEF
      C_TYPE_ADD( &$5.ast->type_id, T_TYPEDEF, @4 );
      C_TYPE_ADD( &$5.ast->type_id, $4, @4 );
      C_AST_CHECK( $5.ast, CHECK_DECL );
      (void)c_ast_take_typedef( $5.ast );

      c_typedef_t const *const found = c_typedef_find( $2->ast->name );
      assert( found != NULL );
      if ( !c_ast_equiv( found->ast, $5.ast ) ) {
        print_error( &@4,
          "\"%s\": \"%s\" redefinition with different type",
          $2->ast->name, L_TYPEDEF
        );
        PARSE_ABORT();
      }
    }
  ;

/*****************************************************************************/
/*  explain                                                                  */
/*****************************************************************************/

explain_declaration_c
  : explain_c type_ast_c { type_push( $2.ast ); } decl_c Y_END
    {
      type_pop();

      DUMP_START( "explain_declaration_c", "EXPLAIN type_ast_c decl_c" );
      DUMP_AST( "type_ast_c", $2.ast );
      DUMP_AST( "decl_c", $4.ast );
      DUMP_END();

      c_ast_t *const ast = c_ast_patch_placeholder( $2.ast, $4.ast );
      C_AST_CHECK( ast, CHECK_DECL );
      char const *name;
      if ( ast->kind == K_OPERATOR ) {
        name = c_graph_name( op_get( ast->as.oper.oper_id )->name );
      } else {
        name = c_ast_take_name( ast );
      }
      assert( name != NULL );
      FPRINTF( fout, "%s %s %s ", L_DECLARE, name, L_AS );
      if ( c_ast_take_typedef( ast ) )
        FPRINTF( fout, "%s ", L_TYPE );
      c_ast_english( ast, fout );
      FPUTC( '\n', fout );
      if ( ast->kind != K_OPERATOR )
        FREE( name );
    }
  ;

explain_cast_c
  : explain_c '(' type_ast_c { type_push( $3.ast ); } cast_opt_c ')' name_opt
    Y_END
    {
      type_pop();

      DUMP_START( "explain_cast_c",
                  "EXPLAIN '(' type_ast_c cast_opt_c ')' name_opt" );
      DUMP_AST( "type_ast_c", $3.ast );
      DUMP_AST( "cast_opt_c", $5.ast );
      DUMP_NAME( "name_opt", $7 );
      DUMP_END();

      c_ast_t *const ast = c_ast_patch_placeholder( $3.ast, $5.ast );
      bool const ok = c_ast_check( ast, CHECK_CAST );
      if ( ok ) {
        FPUTS( L_CAST, fout );
        if ( $7 != NULL )
          FPRINTF( fout, " %s", $7 );
        FPRINTF( fout, " %s ", L_INTO );
        c_ast_english( ast, fout );
        FPUTC( '\n', fout );
      }

      FREE( $7 );
      if ( !ok )
        PARSE_ABORT();
    }
  ;

explain_new_style_cast_c
  : explain_c new_style_cast_c
    lt_expected type_ast_c { type_push( $4.ast ); } cast_opt_c gt_expected
    lparen_expected name_expected rparen_expected
    Y_END
    {
      type_pop();

      DUMP_START( "explain_new_style_cast_c",
                  "EXPLAIN new_style_cast_c '<' type_ast_c cast_opt_c '>' "
                  "'(' NAME ')'" );
      DUMP_LITERAL( "new_style_cast_c", $2 );
      DUMP_AST( "type_ast_c", $4.ast );
      DUMP_AST( "cast_opt_c", $6.ast );
      DUMP_NAME( "name_expected", $9 );
      DUMP_END();

      bool ok = false;
      if ( !C_LANG_IS_CPP() ) {
        print_error( &@2, "%s_cast not supported in %s", $2, C_LANG_NAME() );
      }
      else {
        c_ast_t *const ast = c_ast_patch_placeholder( $4.ast, $6.ast );
        if ( (ok = c_ast_check( ast, CHECK_CAST )) ) {
          FPRINTF( fout, "%s %s %s %s ", $2, L_CAST, $9, L_INTO );
          c_ast_english( ast, fout );
          FPUTC( '\n', fout );
        }
      }

      FREE( $9 );
      if ( !ok )
        PARSE_ABORT();
    }
  ;

explain_using_declaration_c
  : explain_c Y_USING name_expected equals_expected type_ast_c
    {
      // see comment in define_english about T_TYPEDEF
      C_TYPE_ADD( &$5.ast->type_id, T_TYPEDEF, @5 );
      type_push( $5.ast );
    }
    cast_opt_c Y_END
    {
      type_pop();

      DUMP_START( "explain_using_declaration_c",
                  "EXPLAIN USING NAME = type_ast_c cast_opt_c" );
      DUMP_NAME( "NAME", $3 );
      DUMP_AST( "type_ast_c", $5.ast );
      DUMP_AST( "cast_opt_c", $7.ast );
      DUMP_END();

      //
      // Using declarations are supported only in C++11 and later.
      //
      // This check has to be done now in the parser rather than later in the
      // AST because using declarations are treated like typedef declarations
      // and the AST has no "memory" that such a declaration was a using
      // declaration.
      //
      bool ok = false;
      if ( opt_lang < LANG_CPP_11 ) {
        print_error( &@2,
          "\"%s\" not supported in %s", L_USING, C_LANG_NAME()
        );
      }
      else {
        c_ast_t *const ast = c_ast_patch_placeholder( $5.ast, $7.ast );
        if ( (ok = c_ast_check( ast, CHECK_DECL )) ) {
          // Once the semantic checks pass, remove the T_TYPEDEF.
          (void)c_ast_take_typedef( ast );
          FPRINTF( fout, "%s %s %s %s ", L_DECLARE, $3, L_AS, L_TYPE );
          c_ast_english( ast, fout );
          FPUTC( '\n', fout );
        }
      }

      FREE( $3 );
      if ( !ok )
        PARSE_ABORT();
    }
  ;

explain_c
  : Y_EXPLAIN
    {
      //
      // Tell the lexer that we're explaining gibberish so cdecl keywords
      // (e.g., "func") are returned as ordinary names, otherwise gibberish
      // like:
      //
      //      int func(void);
      //
      // would result in a parser error.
      //
      c_mode = MODE_GIBBERISH_TO_ENGLISH;
    }
  ;

new_style_cast_c
  : Y_CONST_CAST                  { $$ = L_CONST;       }
  | Y_DYNAMIC_CAST                { $$ = L_DYNAMIC;     }
  | Y_REINTERPRET_CAST            { $$ = L_REINTERPRET; }
  | Y_STATIC_CAST                 { $$ = L_STATIC;      }
  ;

/*****************************************************************************/
/*  help                                                                     */
/*****************************************************************************/

help_command
  : Y_HELP Y_END                  { print_help(); }
  ;

/*****************************************************************************/
/*  set                                                                      */
/*****************************************************************************/

set_command
  : Y_SET set_option Y_END        { set_option( $2 ); FREE( $2 ); }
  ;

set_option
  : name_opt
  | Y_LANG_NAME
  ;

/*****************************************************************************/
/*  show
/*****************************************************************************/

show_command
  : Y_SHOW Y_TYPEDEF_TYPE typedef_opt Y_END
    {
      if ( $3 )
        print_type_gibberish( $2 );
      else
        print_type_english( $2 );
    }

  | Y_SHOW Y_NAME typedef_opt Y_END
    {
      if ( opt_lang < LANG_CPP_11 ) {
        print_error( &@2,
          "\"%s\": not defined as type via %s or %s",
          $2, L_DEFINE, L_TYPEDEF
        );
      } else {
        print_error( &@2,
          "\"%s\": not defined as type via %s, %s, or %s",
          $2, L_DEFINE, L_TYPEDEF, L_USING
        );
      }
      FREE( $2 );
      PARSE_ABORT();
    }

  | Y_SHOW show_which_types_opt typedef_opt Y_END
    {
      print_type_info_t pti;
      pti.print_fn = $3 ? &print_type_gibberish : &print_type_english;
      pti.show_which = $2;
      (void)c_typedef_visit( &print_type_visitor, &pti );
    }

  | Y_SHOW error
    {
      ELABORATE_ERROR(
        "type name or \"%s\", \"%s\", or \"%s\" expected",
        L_ALL, L_PREDEFINED, L_USER
      );
    }
  ;

show_which_types_opt
  : /* empty */                   { $$ = SHOW_USER_TYPES; }
  | Y_ALL                         { $$ = SHOW_ALL_TYPES; }
  | Y_PREDEFINED                  { $$ = SHOW_PREDEFINED_TYPES; }
  | Y_USER                        { $$ = SHOW_USER_TYPES; }
  ;

/*****************************************************************************/
/*  typedef                                                                  */
/*****************************************************************************/

typedef_declaration_c
  : Y_TYPEDEF
    {
      //
      // Tell the lexer that we're typedef'ing gibberish so cdecl keywords
      // (e.g., "func") are returned as ordinary names, otherwise gibberish
      // like:
      //
      //      typedef int (*func)(void);
      //
      // would result in a parser error.
      //
      c_mode = MODE_GIBBERISH_TO_ENGLISH;
    }
    type_ast_c
    {
      // see comment in define_english about T_TYPEDEF
      C_TYPE_ADD( &$3.ast->type_id, T_TYPEDEF, @3 );
      type_push( $3.ast );
    }
    decl_c Y_END
    {
      type_pop();

      DUMP_START( "typedef_declaration_c", "TYPEDEF type_ast_c decl_c" );
      DUMP_AST( "type_ast_c", $3.ast );
      DUMP_AST( "decl_c", $5.ast );

      c_ast_t *ast;

      if ( $3.ast->kind == K_TYPEDEF && $5.ast->kind == K_TYPEDEF ) {
        //
        // This is for a case like:
        //
        //      typedef size_t foo;
        //
        // that is: an existing typedef name followed by a new name.
        //
        ast = $3.ast;
      }
      else if ( $5.ast->kind == K_TYPEDEF ) {
        //
        // This is for a case like:
        //
        //      typedef int int_least32_t;
        //
        // that is: a type followed by an existing typedef name, i.e.,
        // redefining an existing typedef name to be the same type.
        //
        ast = $3.ast;
        c_ast_set_name( ast, check_strdup( $5.ast->as.c_typedef->ast->name ) );
      }
      else {
        //
        // This is for a case like:
        //
        //      typedef int foo;
        //
        // that is: a type followed by a new name.
        //
        ast = c_ast_patch_placeholder( $3.ast, $5.ast );
        c_ast_set_name( ast, c_ast_take_name( $5.ast ) );
      }

      C_AST_CHECK( ast, CHECK_DECL );
      // see comment in define_english about T_TYPEDEF
      (void)c_ast_take_typedef( ast );

      if ( c_typedef_add( ast ) ) {
        // see comment in define_english about ast_typedef_list
        slist_append_list( &ast_typedef_list, &ast_gc_list );
      }
      else {
        print_error( &@5,
          "\"%s\": \"%s\" redefinition with different type",
          ast->name, L_TYPEDEF
        );
        PARSE_ABORT();
      }

      DUMP_AST( "typedef_declaration_c", ast );
      DUMP_END();
    }
  ;

/*****************************************************************************/
/*  using                                                                    */
/*****************************************************************************/

using_declaration_c
  : Y_USING
    {
      //
      // Tell the lexer that we're typedef'ing gibberish so cdecl keywords
      // (e.g., "func") are returned as ordinary names, otherwise gibberish
      // like:
      //
      //      using func = int (*)(void);
      //
      // would result in a parser error.
      //
      c_mode = MODE_GIBBERISH_TO_ENGLISH;
    }
    name_or_typedef_type_ast_c equals_expected type_ast_c
    {
      // see comment in define_english about T_TYPEDEF
      C_TYPE_ADD( &$5.ast->type_id, T_TYPEDEF, @5 );
      type_push( $5.ast );
    }
    cast_opt_c Y_END
    {
      type_pop();

      //
      // Using declarations are supported only in C++11 and later.  (However,
      // we always allow them in configuration files.)
      //
      // This check has to be done now in the parser rather than later in the
      // AST because using declarations are treated like typedef declarations
      // and the AST has no "memory" that such a declaration was a using
      // declaration.
      //
      if ( c_init >= INIT_READ_CONF && opt_lang < LANG_CPP_11 ) {
        print_error( &@1,
          "\"%s\" not supported in %s", L_USING, C_LANG_NAME()
        );
        PARSE_ABORT();
      }

      DUMP_START( "using_declaration_c", "USING NAME = decl_c" );
      DUMP_AST( "name_or_typedef_type_ast_c", $3.ast );
      DUMP_AST( "type_ast_c", $5.ast );
      DUMP_AST( "cast_opt_c", $7.ast );

      c_ast_t *const ast = c_ast_patch_placeholder( $5.ast, $7.ast );

      char const *const name = $3.ast->kind == K_TYPEDEF ?
        check_strdup( $3.ast->as.c_typedef->ast->name ) :
        c_ast_take_name( $3.ast );
      c_ast_set_name( ast, name );

      C_AST_CHECK( ast, CHECK_DECL );
      // see comment in define_english about T_TYPEDEF
      (void)c_ast_take_typedef( ast );

      if ( c_typedef_add( ast ) ) {
        // see comment in define_english about ast_typedef_list
        slist_append_list( &ast_typedef_list, &ast_gc_list );
      }
      else {
        print_error( &@5,
          "\"%s\": \"%s\" redefinition with different type",
          ast->name, L_USING
        );
        PARSE_ABORT();
      }

      DUMP_AST( "using_declaration_c", ast );
      DUMP_END();
    }
  ;

name_or_typedef_type_ast_c
  : name_ast_c
  | typedef_type_ast_c
  | error
    {
      ELABORATE_ERROR( "type name expected" );
    }
  ;

/*****************************************************************************/
/*  quit                                                                     */
/*****************************************************************************/

quit_command
  : Y_QUIT Y_END                  { quit(); }
  ;

/*****************************************************************************/
/*  declaration english productions                                          */
/*****************************************************************************/

decl_english
  : array_decl_english
  | qualified_decl_english
  | var_decl_english
  ;

array_decl_english
  : Y_ARRAY static_type_opt type_qualifier_list_opt_c array_size_opt_english
    of_expected decl_english
    {
      DUMP_START( "array_decl_english",
                  "ARRAY static_type_opt type_qualifier_list_opt_c "
                  "array_size_opt_english OF decl_english" );
      DUMP_TYPE( "static_type_opt", $2 );
      DUMP_TYPE( "type_qualifier_list_opt_c", $3 );
      DUMP_NUM( "array_size_opt_english", $4 );
      DUMP_AST( "decl_english", $6.ast );

      $$.ast = C_AST_NEW( K_ARRAY, &@$ );
      $$.target_ast = NULL;
      $$.ast->as.array.size = $4;
      $$.ast->as.array.type_id = $2 | $3;
      c_ast_set_parent( $6.ast, $$.ast );

      DUMP_AST( "array_decl_english", $$.ast );
      DUMP_END();
    }

  | Y_VARIABLE length_opt array_expected type_qualifier_list_opt_c of_expected
    decl_english
    {
      DUMP_START( "array_decl_english",
                  "VARIABLE LENGTH ARRAY type_qualifier_list_opt_c "
                  "OF decl_english" );
      DUMP_TYPE( "type_qualifier_list_opt_c", $4 );
      DUMP_AST( "decl_english", $6.ast );

      $$.ast = C_AST_NEW( K_ARRAY, &@$ );
      $$.target_ast = NULL;
      $$.ast->as.array.size = C_ARRAY_SIZE_VARIABLE;
      $$.ast->as.array.type_id = $4;
      c_ast_set_parent( $6.ast, $$.ast );

      DUMP_AST( "array_decl_english", $$.ast );
      DUMP_END();
    }
  ;

array_size_opt_english
  : /* empty */                   { $$ = C_ARRAY_SIZE_NONE; }
  | Y_NUMBER
  | '*'                           { $$ = C_ARRAY_SIZE_VARIABLE; }
  ;

length_opt
  : /* empty */
  | Y_LENGTH
  ;

block_decl_english                      /* Apple extension */
  : Y_BLOCK paren_decl_list_opt_english returning_opt_english
    {
      DUMP_START( "block_decl_english",
                  "BLOCK paren_decl_list_opt_english returning_opt_english" );
      DUMP_TYPE( "(qualifier)", qualifier_peek() );
      DUMP_AST_LIST( "paren_decl_list_opt_english", $2 );
      DUMP_AST( "returning_opt_english", $3.ast );

      $$.ast = C_AST_NEW( K_BLOCK, &@$ );
      $$.target_ast = NULL;
      $$.ast->type_id = qualifier_peek();
      c_ast_set_parent( $3.ast, $$.ast );
      $$.ast->as.block.args = $2;

      DUMP_AST( "block_decl_english", $$.ast );
      DUMP_END();
    }
  ;

func_decl_english
  : ref_qualifier_opt_english member_or_non_member_opt
    Y_FUNCTION paren_decl_list_opt_english returning_opt_english
    {
      DUMP_START( "func_decl_english",
                  "ref_qualifier_opt_english "
                  "member_or_non_member_opt "
                  "FUNCTION paren_decl_list_opt_english "
                  "returning_opt_english" );
      DUMP_TYPE( "(qualifier)", qualifier_peek() );
      DUMP_TYPE( "ref_qualifier_opt_english", $1 );
      DUMP_NUM( "member_or_non_member_opt", $2 );
      DUMP_AST_LIST( "decl_list_opt_english", $4 );
      DUMP_AST( "returning_opt_english", $5.ast );

      $$.ast = C_AST_NEW( K_FUNCTION, &@$ );
      $$.target_ast = NULL;
      $$.ast->type_id = qualifier_peek() | $1;
      $$.ast->as.func.args = $4;
      $$.ast->as.func.flags = $2;
      c_ast_set_parent( $5.ast, $$.ast );

      DUMP_AST( "func_decl_english", $$.ast );
      DUMP_END();
    }
  ;

oper_decl_english
  : type_qualifier_list_opt_c { qualifier_push( $1, &@1 ); }
    ref_qualifier_opt_english member_or_non_member_opt
    Y_OPERATOR paren_decl_list_opt_english returning_opt_english
    {
      qualifier_pop();
      DUMP_START( "oper_decl_english",
                  "member_or_non_member_opt "
                  "OPERATOR paren_decl_list_opt_english "
                  "returning_opt_english" );
      DUMP_TYPE( "ref_qualifier_opt_english", $3 );
      DUMP_NUM( "member_or_non_member_opt", $4 );
      DUMP_AST_LIST( "decl_list_opt_english", $6 );
      DUMP_AST( "returning_opt_english", $7.ast );

      $$.ast = C_AST_NEW( K_OPERATOR, &@$ );
      $$.target_ast = NULL;
      $$.ast->type_id = $1 | $3;
      $$.ast->as.oper.args = $6;
      $$.ast->as.oper.flags = $4;
      c_ast_set_parent( $7.ast, $$.ast );

      DUMP_AST( "oper_decl_english", $$.ast );
      DUMP_END();
    }
  ;

ref_qualifier_opt_english
  : /* empty */                   { $$ = T_NONE; }
  | Y_REFERENCE                   { $$ = T_REFERENCE; }
  | Y_RVALUE reference_expected   { $$ = T_RVALUE_REFERENCE; }
  ;

paren_decl_list_opt_english
  : /* empty */                   { slist_init( &$$ ); }
  | '(' decl_list_opt_english ')'
    {
      DUMP_START( "paren_decl_list_opt_english",
                  "'(' decl_list_opt_english ')'" );
      DUMP_AST_LIST( "decl_list_opt_english", $2 );

      $$ = $2;

      DUMP_AST_LIST( "paren_decl_list_opt_english", $$ );
      DUMP_END();
    }
  ;

decl_list_opt_english
  : /* empty */                   { slist_init( &$$ ); }
  | decl_list_english
  ;

decl_list_english
  : decl_english
    {
      DUMP_START( "decl_list_opt_english", "decl_english" );
      DUMP_AST( "decl_english", $1.ast );

      slist_init( &$$ );
      (void)slist_append( &$$, $1.ast );

      DUMP_AST_LIST( "decl_list_opt_english", $$ );
      DUMP_END();
    }

  | decl_list_english comma_expected decl_english
    {
      DUMP_START( "decl_list_opt_english",
                  "decl_list_opt_english ',' decl_english" );
      DUMP_AST_LIST( "decl_list_opt_english", $1 );
      DUMP_AST( "decl_english", $3.ast );

      $$ = $1;
      (void)slist_append( &$$, $3.ast );

      DUMP_AST_LIST( "decl_list_opt_english", $$ );
      DUMP_END();
    }
  ;

returning_opt_english
  : /* empty */
    {
      DUMP_START( "returning_opt_english", "<empty>" );

      $$.ast = C_AST_NEW( K_BUILTIN, &@$ );
      $$.target_ast = NULL;
      $$.ast->type_id = T_VOID;

      DUMP_AST( "returning_opt_english", $$.ast );
      DUMP_END();
    }

  | Y_RETURNING decl_english
    {
      DUMP_START( "returning_opt_english", "RETURNING decl_english" );
      DUMP_AST( "decl_english", $2.ast );

      $$ = $2;

      DUMP_AST( "returning_opt_english", $$.ast );
      DUMP_END();
    }

  | Y_RETURNING error
    {
      ELABORATE_ERROR( "English expected after \"%s\"", L_RETURNING );
    }
  ;

qualified_decl_english
  : type_qualifier_list_opt_c { qualifier_push( $1, &@1 ); }
    qualifiable_decl_english
    {
      qualifier_pop();
      DUMP_START( "qualified_decl_english",
                  "type_qualifier_list_opt_c qualifiable_decl_english" );
      DUMP_TYPE( "type_qualifier_list_opt_c", $1 );
      DUMP_AST( "qualifiable_decl_english", $3.ast );

      $$ = $3;

      DUMP_AST( "qualified_decl_english", $$.ast );
      DUMP_END();
    }
  ;

qualifiable_decl_english
  : block_decl_english
  | func_decl_english
  | pointer_decl_english
  | reference_decl_english
  | type_english
  ;

pointer_decl_english
  : Y_POINTER to_expected decl_english
    {
      DUMP_START( "pointer_decl_english", "POINTER TO decl_english" );
      DUMP_TYPE( "(qualifier)", qualifier_peek() );
      DUMP_AST( "decl_english", $3.ast );

      if ( $3.ast->kind == K_NAME ) {   // see comment in declare_english
        assert( $3.ast->name != NULL );
        print_error( &@3, "\"%s\": unknown type", $3.ast->name );
        PARSE_ABORT();
      }

      $$.ast = C_AST_NEW( K_POINTER, &@$ );
      $$.target_ast = NULL;
      $$.ast->type_id = qualifier_peek();
      c_ast_set_parent( $3.ast, $$.ast );

      DUMP_AST( "pointer_decl_english", $$.ast );
      DUMP_END();
    }

  | Y_POINTER to_expected Y_MEMBER of_expected
    class_struct_type_expected_c name_expected decl_english
    {
      DUMP_START( "pointer_to_member_decl_english",
                  "POINTER TO MEMBER OF "
                  "class_struct_type_c NAME decl_english" );
      DUMP_TYPE( "(qualifier)", qualifier_peek() );
      DUMP_TYPE( "class_struct_type_c", $5 );
      DUMP_NAME( "NAME", $6 );
      DUMP_AST( "decl_english", $7.ast );

      $$.ast = C_AST_NEW( K_POINTER_TO_MEMBER, &@$ );
      $$.target_ast = NULL;
      $$.ast->type_id = qualifier_peek();
      $$.ast->as.ptr_mbr.class_name = $6;
      c_ast_set_parent( $7.ast, $$.ast );
      C_TYPE_ADD( &$$.ast->type_id, $5, @5 );

      DUMP_AST( "pointer_to_member_decl_english", $$.ast );
      DUMP_END();
    }

  | Y_POINTER to_expected error
    {
      if ( C_LANG_IS_CPP() )
        ELABORATE_ERROR( "type name or \"%s\" expected", L_MEMBER );
      else
        ELABORATE_ERROR( "type name expected" );
    }
  ;

reference_decl_english
  : reference_english to_expected decl_english
    {
      DUMP_START( "reference_decl_english",
                  "reference_english TO decl_english" );
      DUMP_TYPE( "(qualifier)", qualifier_peek() );
      DUMP_AST( "decl_english", $3.ast );

      $$ = $1;
      c_ast_set_parent( $3.ast, $$.ast );
      C_TYPE_ADD( &$$.ast->type_id, qualifier_peek(), qualifier_peek_loc() );

      DUMP_AST( "reference_decl_english", $$.ast );
      DUMP_END();
    }
  ;

reference_english
  : Y_REFERENCE
    {
      $$.ast = C_AST_NEW( K_REFERENCE, &@$ );
      $$.target_ast = NULL;
    }

  | Y_RVALUE reference_expected
    {
      $$.ast = C_AST_NEW( K_RVALUE_REFERENCE, &@$ );
      $$.target_ast = NULL;
    }
  ;

var_decl_english
  : Y_NAME Y_AS decl_english
    {
      DUMP_START( "var_decl_english", "NAME AS decl_english" );
      DUMP_NAME( "NAME", $1 );
      DUMP_AST( "decl_english", $3.ast );

      if ( $3.ast->kind == K_NAME ) {   // see comment in declare_english
        assert( $3.ast->name != NULL );
        print_error( &@3, "\"%s\": unknown type", $3.ast->name );
        FREE( $1 );
        PARSE_ABORT();
      }

      $$ = $3;
      c_ast_set_name( $$.ast, $1 );

      DUMP_AST( "var_decl_english", $$.ast );
      DUMP_END();
    }

  | name_ast_c                          /* K&R C type-less variable */

  | "..."
    {
      DUMP_START( "var_decl_english", "..." );

      $$.ast = C_AST_NEW( K_VARIADIC, &@$ );
      $$.target_ast = NULL;

      DUMP_AST( "var_decl_english", $$.ast );
      DUMP_END();
    }
  ;

/*****************************************************************************/
/*  type english productions                                                 */
/*****************************************************************************/

type_english
  : type_modifier_list_opt_english unmodified_type_english
    {
      DUMP_START( "type_english",
                  "type_modifier_list_opt_english unmodified_type_english" );
      DUMP_TYPE( "type_modifier_list_opt_english", $1 );
      DUMP_AST( "unmodified_type_english", $2.ast );
      DUMP_TYPE( "(qualifier)", qualifier_peek() );

      $$ = $2;
      C_TYPE_ADD( &$$.ast->type_id, qualifier_peek(), qualifier_peek_loc() );
      C_TYPE_ADD( &$$.ast->type_id, $1, @1 );

      DUMP_AST( "type_english", $$.ast );
      DUMP_END();
    }

  | type_modifier_list_english          /* allows implicit int in K&R C */
    {
      DUMP_START( "type_english", "type_modifier_list_english" );
      DUMP_TYPE( "type_modifier_list_english", $1 );
      DUMP_TYPE( "(qualifier)", qualifier_peek() );

      // see comment in type_ast_c
      c_type_id_t type_id = opt_lang < LANG_C_99 ? T_INT : T_NONE;

      C_TYPE_ADD( &type_id, qualifier_peek(), qualifier_peek_loc() );
      C_TYPE_ADD( &type_id, $1, @1 );

      $$.ast = C_AST_NEW( K_BUILTIN, &@$ );
      $$.ast->type_id = type_id;
      $$.target_ast = NULL;

      DUMP_AST( "type_english", $$.ast );
      DUMP_END();
    }
  ;

type_modifier_list_opt_english
  : /* empty */                   { $$ = T_NONE; }
  | type_modifier_list_english
  ;

type_modifier_list_english
  : type_modifier_list_english type_modifier_english
    {
      DUMP_START( "type_modifier_list_english",
                  "type_modifier_list_english type_modifier_english" );
      DUMP_TYPE( "type_modifier_list_english", $1 );
      DUMP_TYPE( "type_modifier_english", $2 );

      $$ = $1;
      C_TYPE_ADD( &$$, $2, @2 );

      DUMP_TYPE( "type_modifier_list_opt_english", $$ );
      DUMP_END();
    }

  | type_modifier_english
  ;

type_modifier_english
  : type_attribute_english
  | Y__COMPLEX
  | Y__IMAGINARY
  | Y_LONG
  | Y_SHORT
  | Y_SIGNED
  | Y_UNSIGNED
  /*
   * Register is here (rather than in storage_class_english) because it's the
   * only storage class that can be specified for function arguments.
   * Therefore, it's simpler to treat it as any other type modifier.
   */
  | Y_REGISTER
  ;

type_attribute_english
  : Y_CARRIES_DEPENDENCY
  | Y_DEPRECATED
  | Y_MAYBE_UNUSED
  | Y_NODISCARD
  ;

unmodified_type_english
  : builtin_type_ast_c
  | enum_class_struct_union_type_ast_c
  | typedef_type_ast_c
  ;

/*****************************************************************************/
/*  declaration gibberish productions                                        */
/*****************************************************************************/

decl_c
  : decl2_c
  | pointer_decl_c
  | pointer_to_member_decl_c
  | reference_decl_c
  ;

decl2_c
  : array_decl_c
  | block_decl_c
  | func_decl_c
  | name_c
  | nested_decl_c
  | oper_decl_c
  | typedef_type_ast_c
  ;

array_decl_c
  : decl2_c array_size_c
    {
      DUMP_START( "array_decl_c", "decl2_c array_size_c" );
      DUMP_AST( "(type_ast_c)", type_peek() );
      DUMP_AST( "decl2_c", $1.ast );
      if ( $1.target_ast != NULL )
        DUMP_AST( "target_ast", $1.target_ast );
      DUMP_NUM( "array_size_c", $2 );

      c_ast_t *const array = C_AST_NEW( K_ARRAY, &@$ );
      array->as.array.size = $2;
      c_ast_set_parent( C_AST_NEW( K_PLACEHOLDER, &@1 ), array );

      if ( $1.target_ast != NULL ) {    // array-of or function/block-ret type
        $$.ast = $1.ast;
        $$.target_ast = c_ast_add_array( $1.target_ast, array );
      } else {
        $$.ast = c_ast_add_array( $1.ast, array );
        $$.target_ast = NULL;
      }

      DUMP_AST( "array_decl_c", $$.ast );
      DUMP_END();
    }
  ;

array_size_c
  : '[' ']'                       { $$ = C_ARRAY_SIZE_NONE; }
  | '[' Y_NUMBER ']'              { $$ = $2; }
  | '[' error ']'
    {
      ELABORATE_ERROR( "integer expected for array size" );
    }
  ;

block_decl_c                            /* Apple extension */
  : /* type */ '(' '^'
    {
      //
      // A block AST has to be the type inherited attribute for decl_c so we
      // have to create it here.
      //
      type_push( C_AST_NEW( K_BLOCK, &@$ ) );
    }
    type_qualifier_list_opt_c decl_c ')' '(' arg_list_opt_c ')'
    {
      c_ast_t *const block = type_pop();

      DUMP_START( "block_decl_c",
                  "'(' '^' type_qualifier_list_opt_c decl_c ')' "
                  "'(' arg_list_opt_c ')'" );
      DUMP_AST( "(type_ast_c)", type_peek() );
      DUMP_TYPE( "type_qualifier_list_opt_c", $4 );
      DUMP_AST( "decl_c", $5.ast );
      DUMP_AST_LIST( "arg_list_opt_c", $8 );

      C_TYPE_ADD( &block->type_id, $4, @4 );
      block->as.block.args = $8;
      $$.ast = c_ast_add_func( $5.ast, type_peek(), block );
      $$.target_ast = block->as.block.ret_ast;

      DUMP_AST( "block_decl_c", $$.ast );
      DUMP_END();
    }
  ;

func_decl_c
  : /* type_ast_c */ decl2_c '(' arg_list_opt_c ')' func_qualifier_list_opt_c
    func_ref_qualifier_opt_c func_noexcept_opt_c
    func_trailing_return_type_opt_c pure_virtual_opt_c
    {
      DUMP_START( "func_decl_c",
                  "decl2_c '(' arg_list_opt_c ')' func_qualifier_list_opt_c "
                  "func_ref_qualifier_opt_c func_noexcept_opt_c "
                  "func_trailing_return_type_opt_c pure_virtual_opt_c" );
      DUMP_AST( "(type_ast_c)", type_peek() );
      DUMP_AST( "decl2_c", $1.ast );
      DUMP_AST_LIST( "arg_list_opt_c", $3 );
      DUMP_TYPE( "func_qualifier_list_opt_c", $5 );
      DUMP_TYPE( "func_ref_qualifier_opt_c", $6 );
      DUMP_TYPE( "func_noexcept_opt_c", $7 );
      DUMP_AST( "func_trailing_return_type_opt_c", $8.ast );
      DUMP_TYPE( "pure_virtual_opt_c", $9 );
      if ( $1.target_ast != NULL )
        DUMP_AST( "target_ast", $1.target_ast );

      c_ast_t *const func = C_AST_NEW( K_FUNCTION, &@$ );
      func->type_id = $5 | $6 | $7 | $9;
      func->as.func.args = $3;

      if ( $8.ast != NULL ) {
        $$.ast = c_ast_add_func( $1.ast, $8.ast, func );
      }
      else if ( $1.target_ast != NULL ) {
        $$.ast = $1.ast;
        (void)c_ast_add_func( $1.target_ast, type_peek(), func );
      }
      else {
        $$.ast = c_ast_add_func( $1.ast, type_peek(), func );
      }
      $$.target_ast = func->as.func.ret_ast;

      DUMP_AST( "func_decl_c", $$.ast );
      DUMP_END();
    }
  ;

func_qualifier_list_opt_c
  : /* empty */                   { $$ = T_NONE; }
  | func_qualifier_list_opt_c func_qualifier_c
    {
      DUMP_START( "func_qualifier_list_opt_c",
                  "func_qualifier_list_opt_c func_qualifier_c" );
      DUMP_TYPE( "func_qualifier_list_opt_c", $1 );
      DUMP_TYPE( "func_qualifier_c", $2 );

      $$ = $1;
      C_TYPE_ADD( &$$, $2, @2 );

      DUMP_TYPE( "func_qualifier_list_opt_c", $$ );
      DUMP_END();
    }
  ;

func_qualifier_c
  : cv_qualifier_c
  | Y_FINAL
  | Y_OVERRIDE
  ;

func_ref_qualifier_opt_c
  : /* empty */                   { $$ = T_NONE; }
  | '&'                           { $$ = T_REFERENCE; }
  | "&&"                          { $$ = T_RVALUE_REFERENCE; }
  ;

func_noexcept_opt_c
  : /* empty */                   { $$ = T_NONE; }
  | Y_NOEXCEPT                    { $$ = T_NOEXCEPT; }
  | Y_NOEXCEPT '(' noexcept_bool rparen_expected
    {
      $$ = $3;
    }
  | Y_THROW lparen_expected rparen_expected
  ;

noexcept_bool
  : Y_FALSE
  | Y_TRUE
  | error
    {
      ELABORATE_ERROR( "\"%s\" or \"%s\" expected", L_TRUE, L_FALSE );
    }
  ;

func_trailing_return_type_opt_c
  : /* empty */                   { $$.ast = $$.target_ast = NULL; }
  | "->" type_ast_c { type_push( $2.ast ); } cast_opt_c
    {
      type_pop();

      //
      // The function trailing return-type syntax is supported only in C++11
      // and later.  This check has to be done now in the parser rather than
      // later in the AST because the AST has no "memory" of where the return-
      // type came from.
      //
      if ( opt_lang < LANG_CPP_11 ) {
        print_error( &@1,
          "trailing return type not supported in %s", C_LANG_NAME()
        );
        PARSE_ABORT();
      }

      //
      // Ensure that a function using the C++11 trailing return type syntax
      // starts with "auto":
      //
      //      void f() -> int
      //      ^
      //      error: must be "auto"
      //
      // This check has to be done now in the parser rather than later in the
      // AST because the "auto" is just a syntactic return-type placeholder in
      // C++11 and the AST node for the placeholder is discarded and never made
      // part of the AST.
      //
      if ( type_peek()->type_id != T_AUTO_CPP_11 ) {
        print_error( &type_peek()->loc,
          "function with trailing return type must specify \"auto\""
        );
        PARSE_ABORT();
      }

      DUMP_START( "func_trailing_return_type_opt_c", "type_ast_c cast_opt_c" );
      DUMP_AST( "(type_ast_c)", type_peek() );
      DUMP_AST( "type_ast_c", $2.ast );
      DUMP_AST( "cast_opt_c", $4.ast );

      $$ = $4.ast ? $4 : $2;

      DUMP_AST( "func_trailing_return_type_opt_c", $$.ast );
      DUMP_END();
    }
  ;

pure_virtual_opt_c
  : /* empty */                   { $$ = T_NONE; }
  | '=' zero_expected             { $$ = T_PURE_VIRTUAL; }
  ;

name_c
  : /* type_ast_c */ Y_NAME
    {
      DUMP_START( "name_c", "NAME" );
      DUMP_AST( "(type_ast_c)", type_peek() );
      DUMP_NAME( "NAME", $1 );

      $$.ast = type_peek();
      $$.target_ast = NULL;
      c_ast_set_name( $$.ast, $1 );

      DUMP_AST( "name_c", $$.ast );
      DUMP_END();
    }
  ;

nested_decl_c
  : '(' placeholder_type_ast_c { type_push( $2.ast ); ++ast_depth; } decl_c ')'
    {
      type_pop();
      --ast_depth;

      DUMP_START( "nested_decl_c", "'(' placeholder_type_ast_c decl_c ')'" );
      DUMP_AST( "placeholder_type_ast_c", $2.ast );
      DUMP_AST( "decl_c", $4.ast );

      $$ = $4;

      DUMP_AST( "nested_decl_c", $$.ast );
      DUMP_END();
    }
  ;

oper_decl_c
  : /* type_ast_c */ oper_c '(' arg_list_opt_c ')'
    func_qualifier_list_opt_c func_ref_qualifier_opt_c func_noexcept_opt_c
    func_trailing_return_type_opt_c pure_virtual_opt_c
    {
      DUMP_START( "oper_decl_c",
                  "OPERATOR c_operator '(' arg_list_opt_c ')' "
                  "func_qualifier_list_opt_c "
                  "func_ref_qualifier_opt_c func_noexcept_opt_c "
                  "func_trailing_return_type_opt_c pure_virtual_opt_c" );
      DUMP_AST( "(type_ast_c)", type_peek() );
      DUMP_AST( "c_operator", $1.ast );
      DUMP_AST_LIST( "arg_list_opt_c", $3 );
      DUMP_TYPE( "func_qualifier_list_opt_c", $5 );
      DUMP_TYPE( "func_ref_qualifier_opt_c", $6 );
      DUMP_TYPE( "func_noexcept_opt_c", $7 );
      DUMP_AST( "func_trailing_return_type_opt_c", $8.ast );
      DUMP_TYPE( "pure_virtual_opt_c", $9 );

      c_ast_t *const oper = C_AST_NEW( K_OPERATOR, &@$ );
      oper->type_id = $5 | $6 | $7 | $9;
      oper->as.oper.args = $3;
      oper->as.oper.oper_id = $1.ast->as.oper.oper_id;

      if ( $8.ast != NULL ) {
        $$.ast = c_ast_add_func( $1.ast, $8.ast, oper );
      }
      else if ( $1.target_ast != NULL ) {
        $$.ast = $1.ast;
        (void)c_ast_add_func( $1.target_ast, type_peek(), oper );
      }
      else {
        $$.ast = c_ast_add_func( $1.ast, type_peek(), oper );
      }
      $$.target_ast = oper->as.oper.ret_ast;

      DUMP_AST( "oper_decl_c", $$.ast );
      DUMP_END();
    }
  ;

oper_c
  : /* type_ast_c */ Y_OPERATOR c_operator
    {
      DUMP_START( "oper_c", "OPERATOR c_operator" );
      DUMP_AST( "(type_ast_c)", type_peek() );
      DUMP_NAME( "c_operator", op_get( $2 )->name );

      $$.ast = type_peek();
      $$.target_ast = NULL;
      $$.ast->as.oper.oper_id = $2;

      DUMP_AST( "oper_c", $$.ast );
      DUMP_END();
    }
  ;

placeholder_type_ast_c
  : /* empty */
    {
      $$.ast = C_AST_NEW( K_PLACEHOLDER, &@$ );
      $$.target_ast = NULL;
    }
  ;

pointer_decl_c
  : pointer_type_c { type_push( $1.ast ); } decl_c
    {
      type_pop();

      DUMP_START( "pointer_decl_c", "pointer_type_c decl_c" );
      DUMP_AST( "pointer_type_c", $1.ast );
      DUMP_AST( "decl_c", $3.ast );

      (void)c_ast_patch_placeholder( $1.ast, $3.ast );
      $$ = $3;

      DUMP_AST( "pointer_decl_c", $$.ast );
      DUMP_END();
    }
  ;

pointer_type_c
  : /* type_ast_c */ '*' type_qualifier_list_opt_c
    {
      DUMP_START( "pointer_type_c", "* type_qualifier_list_opt_c" );
      DUMP_AST( "(type_ast_c)", type_peek() );
      DUMP_TYPE( "type_qualifier_list_opt_c", $2 );

      $$.ast = C_AST_NEW( K_POINTER, &@$ );
      $$.target_ast = NULL;
      $$.ast->type_id = $2;
      c_ast_set_parent( type_peek(), $$.ast );

      DUMP_AST( "pointer_type_c", $$.ast );
      DUMP_END();
    }
  ;

pointer_to_member_decl_c
  : pointer_to_member_type_c { type_push( $1.ast ); } decl_c
    {
      type_pop();

      DUMP_START( "pointer_to_member_decl_c",
                  "pointer_to_member_type_c decl_c" );
      DUMP_AST( "pointer_to_member_type_c", $1.ast );
      DUMP_AST( "decl_c", $3.ast );

      $$ = $3;

      DUMP_AST( "pointer_to_member_decl_c", $$.ast );
      DUMP_END();
    }
  ;

pointer_to_member_type_c
  : /* type_ast_c */ Y_NAME "::" asterisk_expected cv_qualifier_list_opt_c
    {
      DUMP_START( "pointer_to_member_type_c",
                  "NAME :: cv_qualifier_list_opt_c *" );
      DUMP_AST( "(type_ast_c)", type_peek() );
      DUMP_NAME( "NAME", $1 );
      DUMP_TYPE( "cv_qualifier_list_opt_c", $4 );

      $$.ast = C_AST_NEW( K_POINTER_TO_MEMBER, &@$ );
      $$.target_ast = NULL;
      $$.ast->type_id = $4 | T_CLASS;   // assume T_CLASS
      $$.ast->as.ptr_mbr.class_name = $1;
      c_ast_set_parent( type_peek(), $$.ast );

      DUMP_AST( "pointer_to_member_type_c", $$.ast );
      DUMP_END();
    }
  ;

reference_decl_c
  : reference_type_c { type_push( $1.ast ); } decl_c
    {
      type_pop();

      DUMP_START( "reference_decl_c", "reference_type_c decl_c" );
      DUMP_AST( "reference_type_c", $1.ast );
      DUMP_AST( "decl_c", $3.ast );

      $$ = $3;

      DUMP_AST( "reference_decl_c", $$.ast );
      DUMP_END();
    }
  ;

reference_type_c
  : /* type_ast_c */ '&'
    {
      DUMP_START( "reference_type_c", "&" );
      DUMP_AST( "(type_ast_c)", type_peek() );

      $$.ast = C_AST_NEW( K_REFERENCE, &@$ );
      $$.target_ast = NULL;
      c_ast_set_parent( type_peek(), $$.ast );

      DUMP_AST( "reference_type_c", $$.ast );
      DUMP_END();
    }

  | /* type_ast_c */ "&&"
    {
      DUMP_START( "reference_type_c", "&&" );
      DUMP_AST( "(type_ast_c)", type_peek() );

      $$.ast = C_AST_NEW( K_RVALUE_REFERENCE, &@$ );
      $$.target_ast = NULL;
      c_ast_set_parent( type_peek(), $$.ast );

      DUMP_AST( "reference_type_c", $$.ast );
      DUMP_END();
    }
  ;

/*****************************************************************************/
/*  function argument gibberish productions                                  */
/*****************************************************************************/

arg_list_opt_c
  : /* empty */                   { slist_init( &$$ ); }
  | arg_list_c
  ;

arg_list_c
  : arg_list_c comma_expected arg_c
    {
      DUMP_START( "arg_list_c", "arg_list_c ',' arg_c" );
      DUMP_AST_LIST( "arg_list_c", $1 );
      DUMP_AST( "arg_c", $3.ast );

      $$ = $1;
      (void)slist_append( &$$, $3.ast );

      DUMP_AST_LIST( "arg_list_c", $$ );
      DUMP_END();
    }

  | arg_c
    {
      DUMP_START( "arg_list_c", "arg_c" );
      DUMP_AST( "arg_c", $1.ast );

      slist_init( &$$ );
      (void)slist_append( &$$, $1.ast );

      DUMP_AST_LIST( "arg_list_c", $$ );
      DUMP_END();
    }
  ;

arg_c
  : type_ast_c { type_push( $1.ast ); } cast_opt_c
    {
      type_pop();

      DUMP_START( "arg_c", "type_ast_c cast_opt_c" );
      DUMP_AST( "type_ast_c", $1.ast );
      DUMP_AST( "cast_opt_c", $3.ast );

      $$ = $3.ast ? $3 : $1;
      if ( $$.ast->name == NULL )
        $$.ast->name = check_strdup( c_ast_name( $$.ast, V_DOWN ) );

      DUMP_AST( "arg_c", $$.ast );
      DUMP_END();
    }

  | name_ast_c                          /* K&R C type-less argument */

  | "..."
    {
      DUMP_START( "argc", "..." );

      $$.ast = C_AST_NEW( K_VARIADIC, &@$ );
      $$.target_ast = NULL;

      DUMP_AST( "arg_c", $$.ast );
      DUMP_END();
    }
  ;

/*****************************************************************************/
/*  type gibberish productions                                               */
/*****************************************************************************/

type_ast_c
  : type_modifier_list_c                /* allows implicit int in K&R C */
    {
      DUMP_START( "type_ast_c", "type_modifier_list_c" );
      DUMP_TYPE( "type_modifier_list_c", $1 );

      //
      // Prior to C99, typeless declarations are implicitly int, so we set it
      // here.  In C99 and later, however, implicit int is an error, so we
      // don't set it here and c_ast_check() will catch the error later.
      //
      // Note that type modifiers, e.g., unsigned, count as a type since that
      // means unsigned int; however, neither qualifiers, e.g., const, nor
      // storage classes, e.g., register, by themselves count as a type:
      //
      //      unsigned i;   // legal in C99
      //      const    j;   // illegal in C99
      //      register k;   // illegal in C99
      //
      c_type_id_t type_id = opt_lang < LANG_C_99 ? T_INT : T_NONE;

      C_TYPE_ADD( &type_id, $1, @1 );

      $$.ast = C_AST_NEW( K_BUILTIN, &@$ );
      $$.ast->type_id = type_id;
      $$.target_ast = NULL;

      DUMP_AST( "type_ast_c", $$.ast );
      DUMP_END();
    }

  | type_modifier_list_c unmodified_type_c type_modifier_list_opt_c
    {
      DUMP_START( "type_ast_c",
                  "type_modifier_list_c unmodified_type_c "
                  "type_modifier_list_opt_c" );
      DUMP_TYPE( "type_modifier_list_c", $1 );
      DUMP_AST( "unmodified_type_c", $2.ast );
      DUMP_TYPE( "type_modifier_list_opt_c", $3 );

      $$ = $2;
      C_TYPE_ADD( &$$.ast->type_id, $1, @1 );
      C_TYPE_ADD( &$$.ast->type_id, $3, @3 );

      DUMP_AST( "type_ast_c", $$.ast );
      DUMP_END();
    }

  | unmodified_type_c type_modifier_list_opt_c
    {
      DUMP_START( "type_ast_c", "unmodified_type_c type_modifier_list_opt_c" );
      DUMP_AST( "unmodified_type_c", $1.ast );
      DUMP_TYPE( "type_modifier_list_opt_c", $2 );

      $$ = $1;
      C_TYPE_ADD( &$$.ast->type_id, $2, @2 );

      DUMP_AST( "type_ast_c", $$.ast );
      DUMP_END();
    }
  ;

type_modifier_list_opt_c
  : /* empty */                   { $$ = T_NONE; }
  | type_modifier_list_c
  ;

type_modifier_list_c
  : type_modifier_list_c type_modifier_c
    {
      DUMP_START( "type_modifier_list_c",
                  "type_modifier_list_c type_modifier_c" );
      DUMP_TYPE( "type_modifier_list_c", $1 );
      DUMP_TYPE( "type_modifier_c", $2 );

      $$ = $1;
      C_TYPE_ADD( &$$, $2, @2 );

      DUMP_TYPE( "type_modifier_list_c", $$ );
      DUMP_END();
    }

  | type_modifier_c
  ;

type_modifier_c
  : type_modifier_base_c
  | type_qualifier_c
  | storage_class_c
  ;

type_modifier_base_c
  : Y__COMPLEX
  | Y__IMAGINARY
  | Y_LONG
  | Y_SHORT
  | Y_SIGNED
  | Y_UNSIGNED
  /*
   * Register is here (rather than in storage_class_c) because it's the only
   * storage class that can be specified for function arguments.  Therefore,
   * it's simpler to treat it as any other type modifier.
   */
  | Y_REGISTER
  ;

unmodified_type_c
  : atomic_specifier_type_ast_c
  | builtin_type_ast_c
  | enum_class_struct_union_type_ast_c
  | typedef_type_ast_c
  ;

atomic_specifier_type_ast_c
  : Y_ATOMIC_SPEC '(' type_ast_c { type_push( $3.ast ); } cast_opt_c ')'
    {
      type_pop();

      DUMP_START( "atomic_specifier_type_ast_c",
                  "ATOMIC '(' type_ast_c cast_opt_c ')'" );
      DUMP_AST( "type_ast_c", $3.ast );
      DUMP_AST( "cast_opt_c", $5.ast );

      $$ = $5.ast ? $5 : $3;
      C_TYPE_ADD( &$$.ast->type_id, T_ATOMIC, @1 );

      DUMP_AST( "atomic_specifier_type_ast_c", $$.ast );
      DUMP_END();
    }
  ;

builtin_type_ast_c
  : builtin_type_c
    {
      DUMP_START( "builtin_type_ast_c", "builtin_type_c" );
      DUMP_TYPE( "builtin_type_c", $1 );

      $$.ast = C_AST_NEW( K_BUILTIN, &@$ );
      $$.target_ast = NULL;
      $$.ast->type_id = $1;

      DUMP_AST( "builtin_type_ast_c", $$.ast );
      DUMP_END();
    }
  ;

builtin_type_c
  : Y_VOID
  | Y_AUTO_CPP_11
  | Y_BOOL
  | Y_CHAR
  | Y_CHAR16_T
  | Y_CHAR32_T
  | Y_WCHAR_T
  | Y_INT
  | Y_FLOAT
  | Y_DOUBLE
  ;

enum_class_struct_union_type_ast_c
  : enum_class_struct_union_type_c name_expected
    {
      DUMP_START( "enum_class_struct_union_type_ast_c",
                  "enum_class_struct_union_type_c NAME" );
      DUMP_TYPE( "enum_class_struct_union_type_c", $1 );
      DUMP_NAME( "NAME", $2 );

      $$.ast = C_AST_NEW( K_ENUM_CLASS_STRUCT_UNION, &@$ );
      $$.target_ast = NULL;
      $$.ast->type_id = $1;
      $$.ast->as.ecsu.ecsu_name = $2;

      DUMP_AST( "enum_class_struct_union_type_ast_c", $$.ast );
      DUMP_END();
    }
  ;

enum_class_struct_union_type_c
  : Y_ENUM
  | class_struct_type_c
  | Y_ENUM class_struct_type_c    { $$ = $1 | $2; }
  | Y_UNION
  ;

class_struct_type_c
  : Y_CLASS
  | Y_STRUCT
  ;

typedef_type_ast_c
  : Y_TYPEDEF_TYPE
    {
      DUMP_START( "typedef_type_ast_c", "Y_TYPEDEF_TYPE" );
      DUMP_AST( "type_ast", $1->ast );

      $$.ast = C_AST_NEW( K_TYPEDEF, &@$ );
      $$.target_ast = NULL;
      $$.ast->as.c_typedef = $1;
      $$.ast->type_id = T_TYPEDEF_TYPE;

      DUMP_AST( "typedef_type_ast_c", $$.ast );
      DUMP_END();
    }
  ;

type_qualifier_list_opt_c
  : /* empty */                   { $$ = T_NONE; }
  | type_qualifier_list_c
  ;

type_qualifier_list_c
  : type_qualifier_list_c type_qualifier_c
    {
      DUMP_START( "type_qualifier_list_c",
                  "type_qualifier_list_c type_qualifier_c" );
      DUMP_TYPE( "type_qualifier_list_c", $1 );
      DUMP_TYPE( "type_qualifier_c", $2 );

      $$ = $1;
      C_TYPE_ADD( &$$, $2, @2 );

      DUMP_TYPE( "type_qualifier_list_c", $$ );
      DUMP_END();
    }

  | type_qualifier_c
  ;

type_qualifier_c
  : cv_qualifier_c
  | Y_ATOMIC_QUAL
  | Y_RESTRICT
  ;

cv_qualifier_list_opt_c
  : /* empty */                   { $$ = T_NONE; }
  | cv_qualifier_list_opt_c cv_qualifier_c
    {
      DUMP_START( "cv_qualifier_list_opt_c",
                  "cv_qualifier_list_opt_c cv_qualifier_c" );
      DUMP_TYPE( "cv_qualifier_list_opt_c", $1 );
      DUMP_TYPE( "cv_qualifier_c", $2 );

      $$ = $1;
      C_TYPE_ADD( &$$, $2, @2 );

      DUMP_TYPE( "cv_qualifier_list_opt_c", $$ );
      DUMP_END();
    }
  ;

cv_qualifier_c
  : Y_CONST
  | Y_VOLATILE
  ;

storage_class_c
  : attribute_specifier_list_c
  | Y_AUTO_C
  | Y___BLOCK                           /* Apple extension */
  | Y_CONSTEVAL
  | Y_CONSTEXPR
  | Y_EXTERN
  | Y_FINAL
  | Y_FRIEND
  | Y_INLINE
  | Y_MUTABLE
  | Y_NORETURN
  | Y__NORETURN
    {
      if ( !_Noreturn_ok( &@1 ) )
        PARSE_ABORT();
    }
  | Y_OVERRIDE
/*| Y_REGISTER */                       /* in type_modifier_base_c */
  | Y_STATIC
  | Y_TYPEDEF
  | Y_THREAD_LOCAL
  | Y_VIRTUAL
  ;

attribute_specifier_list_c
  : "[[" attribute_name_list_opt_c "]]"
    {
      DUMP_START( "attribute_specifier_list_c",
                  "[[ attribute_name_list_opt_c ]]" );
      DUMP_TYPE( "attribute_name_list_opt_c", $2 );
      DUMP_END();

      $$ = $2;
    }
  ;

attribute_name_list_opt_c
  : /* empty */                   { $$ = T_NONE; }
  | attribute_name_list_c
  ;

attribute_name_list_c
  : attribute_name_list_c comma_expected attribute_name_c
    {
      DUMP_START( "attribute_name_list_c",
                  "attribute_name_list_c , attribute_name_c" );
      DUMP_TYPE( "attribute_name_list_c", $1 );
      DUMP_TYPE( "attribute_name_c", $3 );

      $$ = $1;
      C_TYPE_ADD( &$$, $3, @3 );

      DUMP_TYPE( "attribute_name_list_c", $$ );
      DUMP_END();
    }

  | attribute_name_c
  ;

attribute_name_c
  : name_expected
    {
      DUMP_START( "attribute_name_c", "Y_NAME" );
      DUMP_NAME( "NAME", $1 );
      DUMP_END();

      $$ = T_NONE;

      c_keyword_t const *const a = c_attribute_find( $1 );
      if ( a == NULL ) {
        print_warning( &@1, "\"%s\": unknown attribute", $1 );
      }
      else if ( (opt_lang & a->lang_ids) == LANG_NONE ) {
        print_warning( &@1, "\"%s\" not supported in %s", $1, C_LANG_NAME() );
      }
      else {
        $$ = a->type_id;
      }

      FREE( $1 );
    }
  ;

/*****************************************************************************/
/*  cast gibberish productions                                               */
/*****************************************************************************/

cast_opt_c
  : /* empty */                   { $$.ast = $$.target_ast = NULL; }
  | cast_c
  ;

cast_c
  : cast2_c
  | pointer_cast_c
  | pointer_to_member_cast_c
  | reference_cast_c
  ;

cast2_c
  : array_cast_c
  | block_cast_c
  | func_cast_c
  | name_c
  | nested_cast_c
  ;

array_cast_c
  : /* type */ cast_opt_c arg_array_size_c
    {
      DUMP_START( "array_cast_c", "cast_opt_c array_size_c" );
      DUMP_AST( "(type_ast_c)", type_peek() );
      DUMP_AST( "cast_opt_c", $1.ast );
      if ( $1.target_ast != NULL )
        DUMP_AST( "target_ast", $1.target_ast );
      DUMP_AST( "arg_array_size_c", $2 );

      c_ast_set_parent( C_AST_NEW( K_PLACEHOLDER, &@1 ), $2 );

      if ( $1.target_ast != NULL ) {    // array-of or function/block-ret type
        $$.ast = $1.ast;
        $$.target_ast = c_ast_add_array( $1.target_ast, $2 );
      } else {
        c_ast_t *const ast = $1.ast != NULL ? $1.ast : type_peek();
        $$.ast = c_ast_add_array( ast, $2 );
        $$.target_ast = NULL;
      }

      DUMP_AST( "array_cast_c", $$.ast );
      DUMP_END();
    }
  ;

arg_array_size_c
  : array_size_c
    {
      $$ = C_AST_NEW( K_ARRAY, &@$ );
      $$->as.array.size = $1;
    }
  | '[' type_qualifier_list_c static_type_opt Y_NUMBER ']'
    {
      $$ = C_AST_NEW( K_ARRAY, &@$ );
      $$->as.array.size = $4;
      $$->as.array.type_id = $2 | $3;
    }
  | '[' Y_STATIC type_qualifier_list_opt_c Y_NUMBER ']'
    {
      $$ = C_AST_NEW( K_ARRAY, &@$ );
      $$->as.array.size = $4;
      $$->as.array.type_id = T_STATIC | $3;
    }
  | '[' type_qualifier_list_opt_c '*' ']'
    {
      $$ = C_AST_NEW( K_ARRAY, &@$ );
      $$->as.array.size = C_ARRAY_SIZE_VARIABLE;
      $$->as.array.type_id = $2;
    }
  ;

static_type_opt
  : /* empty */                   { $$ = T_NONE; }
  | Y_STATIC                      { $$ = T_STATIC; }
  ;

block_cast_c                            /* Apple extension */
  : /* type */ '(' '^'
    {
      //
      // A block AST has to be the type inherited attribute for cast_opt_c so
      // we have to create it here.
      //
      type_push( C_AST_NEW( K_BLOCK, &@$ ) );
    }
    type_qualifier_list_opt_c cast_opt_c ')' '(' arg_list_opt_c ')'
    {
      c_ast_t *const block = type_pop();

      DUMP_START( "block_cast_c",
                  "'(' '^' type_qualifier_list_opt_c cast_opt_c ')' "
                  "'(' arg_list_opt_c ')'" );
      DUMP_AST( "(type_ast_c)", type_peek() );
      DUMP_TYPE( "type_qualifier_list_opt_c", $4 );
      DUMP_AST( "cast_opt_c", $5.ast );
      DUMP_AST_LIST( "arg_list_opt_c", $8 );

      C_TYPE_ADD( &block->type_id, $4, @4 );
      block->as.block.args = $8;
      $$.ast = c_ast_add_func( $5.ast, type_peek(), block );
      $$.target_ast = block->as.block.ret_ast;

      DUMP_AST( "block_cast_c", $$.ast );
      DUMP_END();
    }
  ;

func_cast_c
  : /* type_ast_c */ cast2_c '(' arg_list_opt_c ')' func_qualifier_list_opt_c
    func_trailing_return_type_opt_c
    {
      DUMP_START( "func_cast_c",
                  "cast2_c '(' arg_list_opt_c ')' func_qualifier_list_opt_c "
                  "func_trailing_return_type_opt_c" );
      DUMP_AST( "(type_ast_c)", type_peek() );
      DUMP_AST( "cast2_c", $1.ast );
      DUMP_AST_LIST( "arg_list_opt_c", $3 );
      DUMP_TYPE( "func_qualifier_list_opt_c", $5 );
      DUMP_AST( "func_trailing_return_type_opt_c", $6.ast );
      if ( $1.target_ast != NULL )
        DUMP_AST( "target_ast", $1.target_ast );

      c_ast_t *const func = C_AST_NEW( K_FUNCTION, &@$ );
      func->type_id = $5;
      func->as.func.args = $3;

      if ( $6.ast != NULL ) {
        $$.ast = c_ast_add_func( $1.ast, $6.ast, func );
      }
      else if ( $1.target_ast != NULL ) {
        $$.ast = $1.ast;
        (void)c_ast_add_func( $1.target_ast, type_peek(), func );
      }
      else {
        $$.ast = c_ast_add_func( $1.ast, type_peek(), func );
      }
      $$.target_ast = func->as.func.ret_ast;

      DUMP_AST( "func_cast_c", $$.ast );
      DUMP_END();
    }
  ;

nested_cast_c
  : '(' placeholder_type_ast_c
    {
      type_push( $2.ast );
      ++ast_depth;
    }
    cast_opt_c ')'
    {
      type_pop();
      --ast_depth;

      DUMP_START( "nested_cast_c",
                  "'(' placeholder_type_ast_c cast_opt_c ')'" );
      DUMP_AST( "placeholder_type_ast_c", $2.ast );
      DUMP_AST( "cast_opt_c", $4.ast );

      $$ = $4;

      DUMP_AST( "nested_cast_c", $$.ast );
      DUMP_END();
    }
  ;

pointer_cast_c
  : pointer_type_c { type_push( $1.ast ); } cast_opt_c
    {
      type_pop();

      DUMP_START( "pointer_cast_c", "pointer_type_c cast_opt_c" );
      DUMP_AST( "pointer_type_c", $1.ast );
      DUMP_AST( "cast_opt_c", $3.ast );

      $$.ast = c_ast_patch_placeholder( $1.ast, $3.ast );
      $$.target_ast = NULL;

      DUMP_AST( "pointer_cast_c", $$.ast );
      DUMP_END();
    }
  ;

pointer_to_member_cast_c
  : pointer_to_member_type_c { type_push( $1.ast ); } cast_opt_c
    {
      type_pop();

      DUMP_START( "pointer_to_member_cast_c",
                  "pointer_to_member_type_c cast_opt_c" );
      DUMP_AST( "pointer_to_member_type_c", $1.ast );
      DUMP_AST( "cast_opt_c", $3.ast );

      $$.ast = c_ast_patch_placeholder( $1.ast, $3.ast );
      $$.target_ast = NULL;

      DUMP_AST( "pointer_to_member_cast_c", $$.ast );
      DUMP_END();
    }
  ;

reference_cast_c
  : reference_type_c { type_push( $1.ast ); } cast_opt_c
    {
      type_pop();

      DUMP_START( "reference_cast_c", "reference_type_c cast_opt_c" );
      DUMP_AST( "reference_type_c", $1.ast );
      DUMP_AST( "cast_opt_c", $3.ast );

      $$.ast = c_ast_patch_placeholder( $1.ast, $3.ast );
      $$.target_ast = NULL;

      DUMP_AST( "reference_cast_c", $$.ast );
      DUMP_END();
    }
  ;

/*****************************************************************************/
/*  miscellaneous productions                                                */
/*****************************************************************************/

array_expected
  : Y_ARRAY
  | error
    {
      ELABORATE_ERROR( "\"%s\" expected", L_ARRAY );
    }
  ;

as_expected
  : Y_AS
  | error
    {
      ELABORATE_ERROR( "\"%s\" expected", L_AS );
    }
  ;

asterisk_expected
  : '*'
  | error
    {
      ELABORATE_ERROR( "'*' expected" );
    }
  ;

cast_expected
  : Y_CAST
  | error
    {
      ELABORATE_ERROR( "\"%s\" expected", L_CAST );
    }
  ;

class_struct_type_expected_c
  : class_struct_type_c
  | error
    {
      if ( C_LANG_IS_CPP() )
        ELABORATE_ERROR( "\"%s\" or \"%s\" expected", L_CLASS, L_STRUCT );
      else
        ELABORATE_ERROR( "\"%s\" expected", L_STRUCT );
    }
  ;

comma_expected
  : ','
  | error
    {
      ELABORATE_ERROR( "',' expected" );
    }
  ;

c_operator
  : '!'                           { $$ = OP_EXCLAM          ; }
  | "!="                          { $$ = OP_EXCLAM_EQ       ; }
  | '%'                           { $$ = OP_PERCENT         ; }
  | "%="                          { $$ = OP_PERCENT_EQ      ; }
  | '&'                           { $$ = OP_AMPER           ; }
  | "&&"                          { $$ = OP_AMPER2          ; }
  | "&="                          { $$ = OP_AMPER_EQ        ; }
  | '(' rparen_expected           { $$ = OP_PARENS          ; }
  | '*'                           { $$ = OP_STAR            ; }
  | "*="                          { $$ = OP_STAR_EQ         ; }
  | '+'                           { $$ = OP_PLUS            ; }
  | "++"                          { $$ = OP_PLUS2           ; }
  | "+="                          { $$ = OP_PLUS_EQ         ; }
  | ','                           { $$ = OP_COMMA           ; }
  | '-'                           { $$ = OP_MINUS           ; }
  | "--"                          { $$ = OP_MINUS2          ; }
  | "-="                          { $$ = OP_MINUS_EQ        ; }
  | "->"                          { $$ = OP_ARROW           ; }
  | "->*"                         { $$ = OP_ARROW_STAR      ; }
  | '.'                           { $$ = OP_DOT             ; }
  | ".*"                          { $$ = OP_DOT_STAR        ; }
  | '/'                           { $$ = OP_SLASH           ; }
  | "/="                          { $$ = OP_SLASH_EQ        ; }
  | "::"                          { $$ = OP_COLON2          ; }
  | '<'                           { $$ = OP_LESS            ; }
  | "<<"                          { $$ = OP_LESS2           ; }
  | "<<="                         { $$ = OP_LESS2_EQ        ; }
  | "<="                          { $$ = OP_LESS_EQ         ; }
  | "<=>"                         { $$ = OP_LESS_EQ_GREATER ; }
  | '='                           { $$ = OP_EQ              ; }
  | "=="                          { $$ = OP_EQ2             ; }
  | '>'                           { $$ = OP_GREATER         ; }
  | ">>"                          { $$ = OP_GREATER2        ; }
  | ">>="                         { $$ = OP_GREATER2_EQ     ; }
  | ">="                          { $$ = OP_GREATER_EQ      ; }
  | "?:"                          { $$ = OP_QMARK_COLON     ; }
  | '[' rbracket_expected         { $$ = OP_BRACKETS        ; }
  | '^'                           { $$ = OP_CIRC            ; }
  | "^="                          { $$ = OP_CIRC_EQ         ; }
  | '|'                           { $$ = OP_PIPE            ; }
  | "||"                          { $$ = OP_PIPE2           ; }
  | "|="                          { $$ = OP_PIPE_EQ         ; }
  | '~'                           { $$ = OP_TILDE           ; }
  ;

equals_expected
  : '='
  | error
    {
      ELABORATE_ERROR( "'=' expected" );
    }
  ;

gt_expected
  : '>'
  | error
    {
      ELABORATE_ERROR( "'>' expected" );
    }
  ;

into_expected
  : Y_INTO
  | error
    {
      ELABORATE_ERROR( "\"%s\" expected", L_INTO );
    }
  ;

lparen_expected
  : '('
  | error
    {
      ELABORATE_ERROR( "'(' expected" );
    }
  ;

lt_expected
  : '<'
  | error
    {
      ELABORATE_ERROR( "'<' expected" );
    }
  ;

member_or_non_member_opt
  : /* empty */                   { $$ = C_FUNC_UNSPECIFIED; }
  | Y_MEMBER                      { $$ = C_FUNC_MEMBER     ; }
  | Y_NON_MEMBER                  { $$ = C_FUNC_NON_MEMBER ; }
  ;

name_ast_c
  : Y_NAME
    {
      DUMP_START( "name_ast_c", "NAME" );
      DUMP_NAME( "NAME", $1 );

      $$.ast = C_AST_NEW( K_NAME, &@$ );
      $$.target_ast = NULL;
      $$.ast->name = $1;

      DUMP_AST( "name_ast_c", $$.ast );
      DUMP_END();
    }
  ;

name_expected
  : Y_NAME
  | error
    {
      $$ = NULL;
      ELABORATE_ERROR( "name expected" );
    }
  ;

name_opt
  : /* empty */                   { $$ = NULL; }
  | Y_NAME
  ;

of_expected
  : Y_OF
  | error
    {
      ELABORATE_ERROR( "\"%s\" expected", L_OF );
    }
  ;

reference_expected
  : Y_REFERENCE
  | error
    {
      ELABORATE_ERROR( "\"%s\" expected", L_REFERENCE );
    }
  ;

rbracket_expected
  : ']'
  | error
    {
      ELABORATE_ERROR( "']' expected" );
    }
  ;

rparen_expected
  : ')'
  | error
    {
      ELABORATE_ERROR( "')' expected" );
    }
  ;

to_expected
  : Y_TO
  | error
    {
      ELABORATE_ERROR( "\"%s\" expected", L_TO );
    }
  ;

typedef_opt
  : /* empty */                   { $$ = false; }
  | Y_TYPEDEF                     { $$ = true; }
  ;

virtual_expected
  : Y_VIRTUAL
  | error
    {
      ELABORATE_ERROR( "\"%s\" expected", L_VIRTUAL );
    }
  ;

zero_expected
  : Y_NUMBER
    {
      if ( $1 != 0 ) {
        print_error( &@1, "'0' expected" );
        PARSE_ABORT();
      }
    }
  | error
    {
      ELABORATE_ERROR( "'0' expected" );
    }
  ;

%%

/// @endcond

///////////////////////////////////////////////////////////////////////////////
/* vim:set et sw=2 ts=2: */
