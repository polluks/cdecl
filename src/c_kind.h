/*
**      cdecl -- C gibberish translator
**      src/c_kind.h
**
**      Copyright (C) 2017-2019  Paul J. Lucas, et al.
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

#ifndef cdecl_c_kind_H
#define cdecl_c_kind_H

/**
 * @file
 * Declares types and functions for kinds of things in C/C++ declarations.
 */

// local
#include "cdecl.h"                      /* must go first */
#include "typedefs.h"

/// @cond DOXYGEN_IGNORE

// standard
#include <stdbool.h>

_GL_INLINE_HEADER_BEGIN
#ifndef CDECL_KIND_INLINE
# define CDECL_KIND_INLINE _GL_INLINE
#endif /* CDECL_KIND_INLINE */

/// @endcond

///////////////////////////////////////////////////////////////////////////////

/**
 * Kinds of things comprising a C/C++ declaration.
 *
 * A given thing may only have a single kind and \e not be a bitwise-or of
 * kinds.  However, a bitwise-or of kinds may be used to test whether a given
 * thing is any \e one of those kinds.
 */
enum c_kind {
  K_NONE                    = 0,        ///< No kind.
  K_PLACEHOLDER             = 0x00001,  ///< Temporary node in AST.
  K_BUILTIN                 = 0x00002,  ///< `void,` `char,` `int,` etc.
  K_ENUM_CLASS_STRUCT_UNION = 0x00004,  ///< `enum,` `class,` `struct,` `union`
  K_NAME                    = 0x00008,  ///< Typeless function argument in K&R C
  K_TYPEDEF                 = 0x00010,  ///< `typedef` type, e.g., `size_t`.
  K_VARIADIC                = 0x00020,  ///< Variadic (`...`) function argument.
  // "parent" kinds
  K_ARRAY                   = 0x00040,  ///< Array.
  K_BLOCK                   = 0x00080,  ///< Block (Apple extension).
  K_FUNCTION                = 0x00100,  ///< Function.
  K_POINTER                 = 0x00200,  ///< Pointer.
  // "parent" kinds (C++ only)
  K_CONSTRUCTOR             = 0x00400,  ///< Constructor.
  K_DESTRUCTOR              = 0x00800,  ///< Destructor.
  K_OPERATOR                = 0x01000,  ///< Overloaded operator (C++ only).
  K_POINTER_TO_MEMBER       = 0x02000,  ///< Pointer-to-member (C++ only).
  K_REFERENCE               = 0x04000,  ///< Reference (C++ only).
  K_RVALUE_REFERENCE        = 0x08000,  ///< Rvalue reference (C++ only).
  K_USER_DEF_CONVERSION     = 0x10000,  ///< User-defined conversion (C++ only).
  K_USER_DEF_LITERAL        = 0x20000,  ///< User-defined literal (C++ only).
};

/**
 * Shorthand for "function-like" kinds: #K_BLOCK, #K_CONSTRUCTOR,
 * #K_DESTRUCTOR, #K_FUNCTION, #K_OPERATOR, and #K_USER_DEF_LITERAL.
 */
#define K_FUNCTION_LIKE \
  (K_BLOCK | K_CONSTRUCTOR | K_DESTRUCTOR | K_FUNCTION | K_OPERATOR \
  | K_USER_DEF_CONVERSION | K_USER_DEF_LITERAL)

/// @cond DOXYGEN_IGNORE
#define K_PARENT_MIN          K_ARRAY
/// @endcond

////////// extern functions ///////////////////////////////////////////////////

/**
 * Checks whether \a kind is a parent kind.
 *
 * @param kind The <code>\ref c_kind</code> to check.
 * @return Returns `true` only if it is.
 */
CDECL_KIND_INLINE bool c_kind_is_parent( c_kind_t kind ) {
  return kind >= K_PARENT_MIN;
}

/**
 * Gets the name of \a kind.
 *
 * @param kind The <code>\ref c_kind</code> to get the name for.
 * @return Returns said name.
 */
char const* c_kind_name( c_kind_t kind );

///////////////////////////////////////////////////////////////////////////////

_GL_INLINE_HEADER_END

#endif /* cdecl_c_kind_H */
/* vim:set et sw=2 ts=2: */
