/*
**      cdecl -- C gibberish translator
**      src/ast_util.c
**
**      Paul J. Lucas
*/

// local
#include "config.h"                     /* must go first */
#define CDECL_AST_UTIL_INLINE _GL_EXTERN_INLINE
#include "ast_util.h"

// standard
#include <assert.h>
#include <stdbool.h>

// local functions
static c_ast_t* c_ast_append_array( c_ast_t*, c_ast_t* );

////////// local functions ////////////////////////////////////////////////////

/**
 * Adds an array to the AST being built.
 *
 * @param ast The AST to append to.
 * @param array The array AST to append.  It's "of" type must be null.
 * @return Returns the AST to be used as the grammar production's return value.
 */
c_ast_t* c_ast_add_array_impl( c_ast_t *ast, c_ast_t *array ) {
  assert( array != NULL );
  assert( array->kind == K_ARRAY );

  if ( !ast )
    return array;

  switch ( ast->kind ) {
    case K_ARRAY:
      return c_ast_append_array( ast, array );

    case K_NONE:
      c_ast_set_parent( array, ast->parent );
      c_ast_set_parent( ast, array );
      return ast->parent;

    case K_POINTER:
      if ( ast->depth > array->depth ) {
        (void)c_ast_add_array_impl( ast->as.ptr_ref.to_ast, array );
        return ast;
      }
      // no break;

    default:
      if ( ast->depth > array->depth ) {
        if ( c_ast_is_parent( ast ) )
          c_ast_set_parent( ast->as.parent.of_ast, array );
        c_ast_set_parent( array, ast );
        return ast;
      } else {
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
 * @param ast The AST to append to.
 * @param array The array AST to append.  It's "of" type must be null.
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
      // no break;

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
  assert( array->as.array.of_ast->kind == K_NONE );
  //
  // We've reached the end of the array chain: make the new array be an array
  // of this AST node and return the array so the parent will now point to it
  // instead.
  //
  c_ast_set_parent( ast, array );
  return array;
}

/**
 * Adds a function (or block) to the AST being built.
 *
 * @param ast The AST to append to.
 * @param ret_type_ast The AST of the return-type of the function (or block).
 * @param func The function (or block) AST to append.  It's "of" type must be
 * null.
 * @return Returns the AST to be used as the grammar production's return value.
 */
static c_ast_t* c_ast_add_func_impl( c_ast_t *ast, c_ast_t *ret_type_ast,
                                     c_ast_t *func ) {
  assert( ast != NULL );
  assert( func != NULL );
  assert( func->kind & (K_BLOCK | K_FUNCTION) );

  switch ( ast->kind ) {
    case K_ARRAY:
    case K_POINTER:
    case K_POINTER_TO_MEMBER:
    case K_REFERENCE:
    case K_RVALUE_REFERENCE:
      switch ( ast->as.ptr_ref.to_ast->kind ) {
        case K_ARRAY:
        case K_POINTER:
        case K_POINTER_TO_MEMBER:
        case K_REFERENCE:
        case K_RVALUE_REFERENCE:
          (void)c_ast_add_func_impl(
            ast->as.ptr_ref.to_ast, ret_type_ast, func
          );
          return ast;
        case K_NONE:
          if ( ret_type_ast == ast )
            break;
          c_ast_set_parent( func, ast );
          // no break;
        case K_BLOCK:
          c_ast_set_parent( ret_type_ast, func );
          return ast;
        default:
          /* suppress warning */;
      } // switch

    default:
      /* suppress warning */;
  } // switch

  c_ast_set_parent( ret_type_ast, func );
  return func;
}

/**
 * Takes the storage type, if any, away from \a ast
 * (with the intent of giving it to another c_ast).
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
 * i.e., the \c static has to be taken away from \c int and given to the
 * function because it's the function that's \c static, not the \c int.
 *
 * @param ast The AST to take trom.
 * @return Returns said storage class or T_NONE.
 */
static c_type_t c_ast_take_storage( c_ast_t *ast ) {
  c_type_t storage = T_NONE;
  c_ast_t *const found = c_ast_find_kind( ast, V_DOWN, K_BUILTIN );
  if ( found ) {
    storage = found->type & T_MASK_STORAGE;
    found->type &= ~T_MASK_STORAGE;
  }
  return storage;
}

////////// extern functions ///////////////////////////////////////////////////

c_ast_t* c_ast_add_array( c_ast_t *ast, c_ast_t *array ) {
  c_ast_t *const rv = c_ast_add_array_impl( ast, array );
  assert( rv != NULL );
  array->type |= c_ast_take_storage( array->as.array.of_ast );
  return rv;
}

c_ast_t* c_ast_add_func( c_ast_t *ast, c_ast_t *ret_type_ast, c_ast_t *func ) {
  c_ast_t *const rv = c_ast_add_func_impl( ast, ret_type_ast, func );
  assert( rv != NULL );
  func->type |= c_ast_take_storage( func->as.func.ret_ast );
  return rv;
}

char const* c_ast_name( c_ast_t const *ast, v_direction_t dir ) {
  c_ast_t *const nonconst_ast = CONST_CAST( c_ast_t*, ast );
  c_ast_t *const found =
    c_ast_visit( nonconst_ast, dir, c_ast_visitor_name, NULL );
  return found ? found->name : NULL;
}

c_ast_t* c_ast_patch_none( c_ast_t *type_ast, c_ast_t *decl_ast ) {
  if ( !decl_ast )
    return type_ast;
  if ( !type_ast->parent && type_ast->depth < decl_ast->depth ) {
    c_ast_t *const none_ast = c_ast_find_kind( decl_ast, V_DOWN, K_NONE );
    if ( none_ast ) {
      c_ast_t *const type_root_ast = c_ast_root( type_ast );
      c_ast_set_parent( type_root_ast, none_ast->parent );
    }
  }
  return decl_ast;
}

char const* c_ast_take_name( c_ast_t *ast ) {
  c_ast_t *const found = c_ast_visit( ast, V_DOWN, c_ast_visitor_name, NULL );
  if ( !found )
    return NULL;
  char const *const name = found->name;
  found->name = NULL;
  return name;
}

bool c_ast_take_typedef( c_ast_t *ast ) {
  c_ast_t *const found = c_ast_find_kind( ast, V_DOWN, K_BUILTIN );
  if ( found && (found->type & T_TYPEDEF) ) {
    found->type &= ~T_TYPEDEF;
    return true;
  }
  return false;
}

///////////////////////////////////////////////////////////////////////////////
/* vim:set et sw=2 ts=2: */
