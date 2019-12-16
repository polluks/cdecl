/*
**      cdecl -- C gibberish translator
**      src/c_operator.h
**
**      Copyright (C) 2018  Paul J. Lucas, et al.
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

#ifndef cdecl_c_operator_H
#define cdecl_c_operator_H

/**
 * @file
 * Declares constants, macros, types, and functions for C/C++ operators.
 */

// local
#include "cdecl.h"                      /* must go first */
#include "c_ast.h"
#include "c_lang.h"
#include "gibberish.h"

/// @cond DOXYGEN_IGNORE

// standard
#include <stdbool.h>

_GL_INLINE_HEADER_BEGIN
#ifndef CDECL_OP_INLINE
# define CDECL_OP_INLINE _GL_INLINE
#endif /* CDECL_OP_INLINE */

/// @endcond

/**
 * @defgroup cpp-operators-group C++ Operators
 * Macros, types, and functions for C++ operators.
 * @{
 */

#define OP_ARGS_UNLIMITED     (~0u)     /**< Unlimited args for operator(). */

// overloadability
#define OP_NOT_OVERLOADABLE   0u        /**< Operator is not overloadable. */
#define OP_UNSPECIFIED        C_FUNC_UNSPECIFIED
#define OP_MEMBER             C_FUNC_MEMBER
#define OP_NON_MEMBER         C_FUNC_NON_MEMBER
#define OP_OVERLOADABLE       (OP_MEMBER | OP_NON_MEMBER)

// bit masks
#define OP_MASK_OVERLOAD      C_FUNC_MASK_MEMBER

///////////////////////////////////////////////////////////////////////////////

/**
 * C/C++ operators.
 *
 * @note Operators are named based on the characters comprising them rather
 * than their semantics because many operators have more than one meaning
 * depending upon context, e.g. `*` is both the "times" and the "dereference"
 * operator.
 */
enum c_oper_id {
  OP_NONE,            ///< No operator.
  OP_EXCLAM,          ///< The `!` operator.
  OP_EXCLAM_EQ,       ///< The `!=` operator.
  OP_PERCENT,         ///< The `%` operator.
  OP_PERCENT_EQ,      ///< The `%=` operator.
  OP_AMPER,           ///< The `&` operator.
  OP_AMPER2,          ///< The `&&` operator.
  OP_AMPER_EQ,        ///< The `&=` operator.
  OP_PARENS,          ///< The `()` operator.
  OP_STAR,            ///< The `*` operator.
  OP_STAR_EQ,         ///< The `*=` operator.
  OP_PLUS,            ///< The `+` operator.
  OP_PLUS2,           ///< The `++` operator.
  OP_PLUS_EQ,         ///< The `+=` operator.
  OP_COMMA,           ///< The `,` operator.
  OP_MINUS,           ///< The `-` operator.
  OP_MINUS2,          ///< The `--` operator.
  OP_MINUS_EQ,        ///< The `-=` operator.
  OP_ARROW,           ///< The `->` operator.
  OP_ARROW_STAR,      ///< The `->*` operator.
  OP_DOT,             ///< The `.` operator.
  OP_DOT_STAR,        ///< The `.*` operator.
  OP_SLASH,           ///< The `/` operator.
  OP_SLASH_EQ,        ///< The `/=` operator.
  OP_COLON2,          ///< The `::` operator.
  OP_LESS,            ///< The `<` operator.
  OP_LESS2,           ///< The `<<` operator.
  OP_LESS2_EQ,        ///< The `<<=` operator.
  OP_LESS_EQ,         ///< The `<=` operator.
  OP_LESS_EQ_GREATER, ///< The `<=>` operator.
  OP_EQ,              ///< The `=` operator.
  OP_EQ2,             ///< The `==` operator.
  OP_GREATER,         ///< The `>` operator.
  OP_GREATER_EQ,      ///< The `>=` operator.
  OP_GREATER2,        ///< The `>>` operator.
  OP_GREATER2_EQ,     ///< The `>>=` operator.
  OP_QMARK_COLON,     ///< The `?:` operator.
  OP_BRACKETS,        ///< The `[]` operator.
  OP_CIRC,            ///< The `^` operator.
  OP_CIRC_EQ,         ///< The `^=` operator.
  OP_PIPE,            ///< The `|` operator.
  OP_PIPE_EQ,         ///< The `|=` operator.
  OP_PIPE2,           ///< The `||` operator.
  OP_TILDE,           ///< The `~` operator.
};

/**
 * C/C++ operator information.
 *
 * @note: `args_min` and `args_max` comprise the inclusive range for the union
 * of member and non-member versions.  If you know you're dealing with a member
 * operator, use only `args_min`; if you know you're dealing with a non-member
 * operator, use only `args_max`; if you don't know which, use both.
 */
struct c_operator {
  char const *name;                     ///< Name.
  unsigned    flags;                    ///< Bitwise-or of flags.
  unsigned    args_min;                 ///< Minumum number of arguments.
  unsigned    args_max;                 ///< Maximum number of arguments.
  c_lang_id_t lang_ids;                 ///< Language(s) OK in.
};

////////// extern functions ///////////////////////////////////////////////////

/**
 * Gets the `c_operator` for \a oper_id.
 *
 * @param oper_id The ID of the `c_operator` to get.
 * @return Returns a pointer to said `c_operator`.
 */
c_operator_t const* op_get( c_oper_id_t oper_id );

/**
 * Checks whether the C/C++ operator is ambiguous.
 *
 * The operators `&`, `*`, `+`, `++`, `-`, and `--`, when declared as:
 *
 *      T operator OP(U);
 *
 * i.e., taking one argument, are ambiguous (to cdecl) between being a member
 * or non-member operator since cdecl doesn't have the context in which the
 * operator is declared.  If it were declared in-class, e.g.:
 *
 *      class T {
 *      public:
 *        // ...
 *        T& operator OP(U);
 *      };
 *
 * then clearly it's a member operator; if it were declared at file scope, then
 * clearly it's a non-member operator; but cdecl doesn't have this context.
 *
 * We can tell if an operator is ambiguous if it can take 1 argument (when the
 * minimum is 0 and the maximum is 2).
 *
 * @param op The C/C++ operator to check.
 * @return Returns `true` only if the operator is ambiguous.
 */
CDECL_OP_INLINE bool op_is_ambiguous( c_operator_t const *op ) {
  return op->args_min == 0 && op->args_max == 2;
}

/**
 * Gets whether the operator is a member, non-member, or unspecified.
 *
 * @param ast The `c_ast` of the operator.
 * @return Returns one of <code>\ref OP_MEMBER</code>,
 * <code>\ref OP_NON_MEMBER</code>, or <code>\ref OP_UNSPECIFIED</code>.
 */
unsigned op_get_overload( c_ast_t const *ast );

/**
 * Gets the C/C++ token for the operator having \a oper_id.
 *
 * @param oper_id The ID of the `c_operator` to get the token for.
 * @return Returns said token; otherwise, returns theunaltered token.
 */
CDECL_OP_INLINE char const* op_token_c( c_oper_id_t oper_id ) {
  return alt_token_c( graph_token_c( op_get( oper_id )->name ) );
}

///////////////////////////////////////////////////////////////////////////////

/** @} */

_GL_INLINE_HEADER_END

#endif /* cdecl_c_operator_H */
/* vim:set et sw=2 ts=2: */
