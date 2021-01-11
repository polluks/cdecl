/*
**      cdecl -- C gibberish translator
**      src/c_keyword.h
**
**      Copyright (C) 2017-2021  Paul J. Lucas, et al.
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

#ifndef cdecl_c_keyword_H
#define cdecl_c_keyword_H

/**
 * @file
 * Declares types and functions for looking up C/C++ keyword or C++11 (or
 * later) attribute information.
 */

// local
#include "pjl_config.h"                 /* must go first */
#include "types.h"

/**
 * @defgroup c-keywords-group C/C++ Keywords
 * Types and functions for C/C++ keywords or C++11 (or later) attributes.
 * @{
 */

///////////////////////////////////////////////////////////////////////////////

/**
 * C++ keywords contexts.  A context specifies where particular literals are
 * recognized as keywords.  For example, `final` and `override` are recognized
 * as keywords only within member function declarations.
 */
enum c_keyword_ctx {
  C_KW_CTX_ALL,                         ///< All contexts.
  C_KW_CTX_MBR_FUNC                     ///< Member function declaration.
};

/**
 * C/C++ language keyword or C++11 (or later) attribute information.
 */
struct c_keyword {
  char const     *literal;              ///< C string literal of the keyword.
  int             yy_token_id;          ///< Bison token number.
  c_lang_id_t     lang_ids;             ///< Language(s) OK in.
  c_keyword_ctx_t context;              ///< Keyword context.
  c_type_id_t     type_id;              ///< Type the keyword maps to, if any.
};

////////// extern functions ///////////////////////////////////////////////////

/**
 * Given a literal, gets the `c_keyword` for the corresponding C++11 (or later)
 * attribute, e.g., `[[deprecated]]`.
 * @note The search is _sensitive_ to the current language.
 *
 * @param literal The literal to find.
 * @return Returns a pointer to the corresponding attribute (`c_keyword`) or
 * null for none.
 */
PJL_WARN_UNUSED_RESULT
c_keyword_t const* c_attribute_find( char const *literal );

/**
 * Given a literal, gets the `c_keyword` for the corresponding C/C++ keyword.
 * @note The search is _insensitive_ to the current language.
 *
 * @param literal The literal to find.
 * @param lang_ids The bitwise-or of language(s) to look for the keyword in.
 * @param kw_ctx The keyword context to limit to.
 * @return Returns a pointer to the corresponding `c_keyword` or null for none.
 */
PJL_WARN_UNUSED_RESULT
c_keyword_t const* c_keyword_find( char const *literal, c_lang_id_t lang_ids,
                                   c_keyword_ctx_t kw_ctx );

/**
 * Iterates to the next C/C++ keyword.
 *
 * @param k A pointer to the previous keyword. For the first iteration, NULL
 * should be passed.
 * @return Returns the next C/C++ keyword or null for none.
 */
PJL_WARN_UNUSED_RESULT
c_keyword_t const* c_keyword_next( c_keyword_t const *k );

///////////////////////////////////////////////////////////////////////////////

/** @} */

#endif /* cdecl_c_keyword_H */
/* vim:set et sw=2 ts=2: */
