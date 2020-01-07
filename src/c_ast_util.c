/*
**      cdecl -- C gibberish translator
**      src/c_ast_util.c
**
**      Copyright (C) 2017-2020  Paul J. Lucas, et al.
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
 * Defines functions for various cdecl-specific algorithms for construcing an
 * Abstract Syntax Tree (AST) for parsed C/C++ declarations.
 */

// local
#include "cdecl.h"                      /* must go first */
#include "c_ast_util.h"
#include "c_typedef.h"

/// @cond DOXYGEN_IGNORE

// standard
#include <assert.h>
#include <stdbool.h>

/// @endcond

// local functions
static c_ast_t* c_ast_append_array( c_ast_t*, c_ast_t* );

////////// local functions ////////////////////////////////////////////////////

/**
 * Adds an array to the AST being built.
 *
 * @param ast The `c_ast` to append to.
 * @param array The array `c_ast` to append.  Its "of" type must be null.
 * @return Returns the `c_ast` to be used as the grammar production's return
 * value.
 */
static c_ast_t* c_ast_add_array_impl( c_ast_t *ast, c_ast_t *array ) {
  assert( array != NULL );
  assert( array->kind == K_ARRAY );

  if ( ast == NULL )
    return array;

  switch ( ast->kind ) {
    case K_ARRAY:
      return c_ast_append_array( ast, array );

    case K_POINTER:
      if ( ast->depth > array->depth ) {
        (void)c_ast_add_array_impl( ast->as.ptr_ref.to_ast, array );
        return ast;
      }
      // FALLTHROUGH

    default:
      //
      // An AST node's "depth" says how nested within () it is and controls the
      // precendence of what is an array of what.
      //
      if ( ast->depth > array->depth ) {
        //
        // Before:
        //
        //      [ast-child] --> [ast]
        //      [array]
        //
        // After:
        //
        //      [ast-child] --> [array] --> [ast]
        //
        if ( c_ast_is_parent( ast ) )
          c_ast_set_parent( ast->as.parent.of_ast, array );
        c_ast_set_parent( array, ast );
        return ast;
      }
      else {
        //
        // Before:
        //
        //      [ast] --> [parent]
        //      [array]
        //
        // After:
        //
        //      [ast] --> [array] --> [parent]
        //
        if ( c_ast_is_parent( ast->parent ) )
          c_ast_set_parent( array, ast->parent );
        c_ast_set_parent( ast, array );
        return array;
      }
  } // switch
}

/**
 * If \a ast is:
 *  + Not an array, makes \a array an array of \a ast.
 *  + An array, appends \a array to the end of the array AST chain.
 *
 * For example, given:
 *
 *  + \a ast = <code>array 3 of array 5 of int</code>
 *  + \a array = <code>array 7 of NULL</code>
 *
 * this function returns:
 *
 *  + <code>array 3 of array 5 of array 7 of int</code>
 *
 * @param ast The `c_ast` to append to.
 * @param array The array `c_ast` to append.  Its "of" type must be null.
 * @return If \a ast is an array, returns \a ast; otherwise returns \a array.
 */
static c_ast_t* c_ast_append_array( c_ast_t *ast, c_ast_t *array ) {
  assert( ast != NULL );
  assert( array != NULL );

  switch ( ast->kind ) {
    case K_POINTER:
      //
      // If there's an intervening pointer, e.g.:
      //
      //      type (*(*x)[3])[5]
      //
      // (where 'x' is a "pointer to array 3 of pointer to array 5 of int"), we
      // have to recurse "through" it if its depth < the array's depth; else
      // we'd end up with a "pointer to array 3 of array 5 of pointer to int."
      //
      if ( array->depth >= ast->depth )
        break;
      // FALLTHROUGH

    case K_ARRAY: {
      //
      // On the next-to-last recursive call, this sets this array to be an
      // array of the new array; for all prior recursive calls, it's a no-op.
      //
      c_ast_t *const temp = c_ast_append_array( ast->as.array.of_ast, array );
      c_ast_set_parent( temp, ast );
      return ast;
    }

    default:
      /* suppress warning */;
  } // switch

  assert( array->kind == K_ARRAY );
  assert( array->as.array.of_ast->kind == K_PLACEHOLDER );
  //
  // We've reached the end of the array chain: make the new array be an array
  // of this AST node and return the array so the parent will now point to it
  // instead.
  //
  c_ast_set_parent( ast, array );
  return array;
}

/**
 * Adds a function-like AST to the AST being built.
 *
 * @param ast The `c_ast` to append to.
 * @param ret_ast The `c_ast` of the return-type of the function-like AST.
 * @param func_ast The function-like AST to append.  Its "of" type must be
 * null.
 * @return Returns the `c_ast` to be used as the grammar production's return
 * value.
 */
static c_ast_t* c_ast_add_func_impl( c_ast_t *ast, c_ast_t *ret_ast,
                                     c_ast_t *func_ast ) {
  assert( ast != NULL );
  assert( func_ast != NULL );
  assert( (func_ast->kind & K_FUNCTION_LIKE) != K_NONE );

  if ( (ast->kind & (K_ARRAY | K_ANY_POINTER | K_ANY_REFERENCE)) != K_NONE ) {
    switch ( ast->as.parent.of_ast->kind ) {
      case K_ARRAY:
      case K_POINTER:
      case K_POINTER_TO_MEMBER:
      case K_REFERENCE:
      case K_RVALUE_REFERENCE:
        (void)c_ast_add_func_impl( ast->as.ptr_ref.to_ast, ret_ast, func_ast );
        return ast;

      case K_PLACEHOLDER:
        if ( ret_ast == ast )
          break;
        c_ast_set_parent( func_ast, ast );
        // FALLTHROUGH

      case K_BLOCK:                   // Apple extension
        c_ast_set_parent( ret_ast, func_ast );
        return ast;

      default:
        /* suppress warning */;
    } // switch
  }

  c_ast_set_parent( ret_ast, func_ast );
  return func_ast;
}

/**
 * Takes the storage type, if any, away from \a ast
 * (with the intent of giving it to another `c_ast`).
 * This is used is cases like:
 * @code
 *  explain static int f()
 * @endcode
 * that should be explained as:
 * @code
 *  declare f as static function () returning int
 * @endcode
 * and \e not:
 * @code
 *  declare f as function () returning static int
 * @endcode
 * i.e., the `static` has to be taken away from `int` and given to the function
 * because it's the function that's `static`, not the `int`.
 *
 * @param ast The `c_ast` to take trom.
 * @return Returns said storage class or <code>\ref T_NONE</code>.
 */
static c_type_id_t c_ast_take_storage( c_ast_t *ast ) {
  assert( ast != NULL );
  c_type_id_t storage_type = T_NONE;
  c_ast_t *const found
    = c_ast_find_kind( ast, C_VISIT_DOWN, K_BUILTIN | K_TYPEDEF );
  if ( found != NULL ) {
    storage_type = found->type_id & (T_MASK_ATTRIBUTE | T_MASK_STORAGE);
    found->type_id &= ~(T_MASK_ATTRIBUTE | T_MASK_STORAGE);
  }
  return storage_type;
}

/**
 * A visitor function to find an AST node having a particular kind.
 *
 * @param ast The `c_ast` to check.
 * @param data The bitwise-or of <code>\ref c_kind</code> (cast to `void*`) to
 * find.
 * @return Returns `true` only if the kind of \a ast is one of \a data.
 */
static bool c_ast_vistor_kind( c_ast_t *ast, void *data ) {
  assert( ast != NULL );
  c_kind_t const kind = c_kind_data_get( data );
  return (ast->kind & kind) != K_NONE;
}

/**
 * A visitor function to find an AST node having a particular name.
 *
 * @param ast The `c_ast` to check.
 * @param data The least number of names that the scoped name must have.
 * @return Returns `true` only if \a ast has such a scoped name.
 */
static bool c_ast_visitor_name( c_ast_t *ast, void *data ) {
  assert( ast != NULL );
  uintptr_t const at_least = REINTERPRET_CAST( uintptr_t, data );
  return c_ast_sname_count( ast ) >= at_least;
}

/**
 * A visitor function to find an AST node having a particular type.
 *
 * @param ast The `c_ast` to check.
 * @param data The bitwise-or of <code>\ref c_type_id_t</code> (cast to
 * `void*`) to find.
 * @return Returns `true` only if the type of \a ast is one of \a data.
 */
static bool c_ast_vistor_type( c_ast_t *ast, void *data ) {
  assert( ast != NULL );
  c_type_id_t const type_id = c_type_id_data_get( data );
  return (ast->type_id & type_id) != T_NONE;
}

////////// extern functions ///////////////////////////////////////////////////

c_ast_t* c_ast_add_array( c_ast_t *ast, c_ast_t *array ) {
  assert( ast != NULL );
  c_ast_t *const rv = c_ast_add_array_impl( ast, array );
  assert( rv != NULL );
  array->type_id |= c_ast_take_storage( array->as.array.of_ast );
  return rv;
}

c_ast_t* c_ast_add_func( c_ast_t *ast, c_ast_t *ret_ast, c_ast_t *func ) {
  assert( ast != NULL );
  c_ast_t *const rv = c_ast_add_func_impl( ast, ret_ast, func );
  assert( rv != NULL );
  if ( c_ast_sname_empty( func ) )
    func->sname = c_ast_take_name( ast );
  func->type_id |= c_ast_take_storage( func->as.func.ret_ast );
  return rv;
}

c_ast_t* c_ast_find_kind( c_ast_t *ast, v_direction_t dir, c_kind_t kind ) {
  void *const data = c_kind_data_new( kind );
  ast = c_ast_visit( ast, dir, c_ast_vistor_kind, data );
  c_kind_data_free( data );
  return ast;
}

c_sname_t* c_ast_find_name( c_ast_t const *ast, v_direction_t dir ) {
  c_ast_t *const nonconst_ast = CONST_CAST( c_ast_t*, ast );
  c_ast_t *const found = c_ast_visit(
    nonconst_ast, dir, c_ast_visitor_name, REINTERPRET_CAST( void*, 1 )
  );
  return found != NULL ? &found->sname : NULL;
}

c_ast_t* c_ast_find_type( c_ast_t *ast, v_direction_t dir,
                          c_type_id_t type_id ) {
  void *const data = c_type_id_data_new( type_id );
  ast = c_ast_visit( ast, dir, c_ast_vistor_type, data );
  c_type_id_data_free( data );
  return ast;
}

bool c_ast_is_builtin( c_ast_t const *ast, c_type_id_t type_id ) {
  ast = c_ast_untypedef( ast );
  return  ast->kind == K_BUILTIN &&
          (type_id == T_NONE || (ast->type_id & type_id) != T_NONE);
}

bool c_ast_is_ecsu( c_ast_t const *ast ) {
  ast = c_ast_unreference( ast );
  return ast != NULL && ast->kind == K_ENUM_CLASS_STRUCT_UNION;
}

bool c_ast_is_ptr_to_type( c_ast_t const *ast, c_type_id_t type_id ) {
  return  (ast = c_ast_unpointer( ast )) != NULL &&
          (ast->type_id & type_id) != T_NONE;
}

bool c_ast_is_ref_to_type( c_ast_t const *ast, c_type_id_t type_id ) {
  return  (ast = c_ast_unreference( ast )) != NULL &&
          (ast->type_id & type_id) != T_NONE;
}

c_ast_t* c_ast_patch_placeholder( c_ast_t *type_ast, c_ast_t *decl_ast ) {
  assert( type_ast != NULL );
  if ( decl_ast == NULL )
    return type_ast;

  if ( type_ast->parent == NULL ) {
    c_ast_t *const placeholder =
      c_ast_find_kind( decl_ast, C_VISIT_DOWN, K_PLACEHOLDER );
    if ( placeholder != NULL ) {
      if ( type_ast->depth >= decl_ast->depth ) {
        //
        // The type_ast is the final AST -- decl_ast (containing a placeholder)
        // is discarded.
        //
        if ( c_ast_sname_empty( type_ast ) )
          type_ast->sname = c_ast_take_name( decl_ast );
        return type_ast;
      }
      //
      // Otherwise, excise the K_PLACEHOLDER.
      // Before:
      //
      //      [type] --> ... --> [type-root]
      //      [placeholder] --> [placeholder-parent]
      //
      // After:
      //
      //      [type] --> ... --> [type-root] --> [placeholder-parent]
      //
      c_ast_t *const type_root_ast = c_ast_root( type_ast );
      c_ast_set_parent( type_root_ast, placeholder->parent );
    }
  }

  //
  // The decl_ast is the final AST -- type_ast may be discarded (if it wasn't
  // patched in), so take its name if we don't have one already.
  //
  if ( c_ast_sname_empty( decl_ast ) )
    decl_ast->sname = c_ast_take_name( type_ast );
  return decl_ast;
}

c_sname_t c_ast_take_name( c_ast_t *ast ) {
  assert( ast != NULL );
  c_sname_t *const found = c_ast_find_name( ast, C_VISIT_DOWN );
  c_sname_t rv;
  if ( found == NULL ) {
    c_sname_init( &rv );
  } else {
    rv = *found;
    c_sname_init( found );
  }
  return rv;
}

bool c_ast_take_typedef( c_ast_t *ast ) {
  assert( ast != NULL );
  c_ast_t *const found = c_ast_find_type( ast, C_VISIT_DOWN, T_TYPEDEF );
  if ( found != NULL ) {
    found->type_id &= ~T_TYPEDEF;
    return true;
  }
  return false;
}

c_ast_t const* c_ast_unpointer( c_ast_t const *ast ) {
  ast = c_ast_untypedef( ast );
  return ast != NULL && ast->kind == K_POINTER ?
    c_ast_untypedef( ast->as.ptr_ref.to_ast ) : NULL;
}

c_ast_t const* c_ast_unreference( c_ast_t const *ast ) {
  while ( (ast = c_ast_untypedef( ast )) != NULL &&
          (ast->kind & K_REFERENCE) != K_NONE ) {
    ast = ast->as.ptr_ref.to_ast;
    assert( ast != NULL );
  } // while
  return ast;
}

c_ast_t const* c_ast_untypedef( c_ast_t const *ast ) {
  if ( ast != NULL ) {
    while ( ast->kind == K_TYPEDEF ) {
      ast = ast->as.c_typedef->ast;
      assert( ast != NULL );
    } // while
  }
  return ast;
}

///////////////////////////////////////////////////////////////////////////////
/* vim:set et sw=2 ts=2: */
