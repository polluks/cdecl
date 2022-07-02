/*
**      cdecl -- C gibberish translator
**      src/red_black.c
**
**      Copyright (C) 2017-2022  Paul J. Lucas, et al.
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

/*
 * Adapted from the code:
 * <https://opensource.apple.com/source/sudo/sudo-46/src/redblack.c>
 */

/*
 * Copyright (c) 2004-2005, 2007 Todd C. Miller <Todd.Miller@courtesan.com>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 */

/*
 * Adapted from the code written by Emin Martinian:
 * <http://web.mit.edu/~emin/www/source_code/red_black_tree/index.html>
 *
 * Copyright (c) 2001 Emin Martinian
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that neither the name of Emin
 * Martinian nor the names of any contributors are be used to endorse or
 * promote products derived from this software without specific prior
 * written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
 * "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
 * LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
 * A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
 * OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
 * SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
 * LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
 * DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
 * THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

/**
 * @file
 * Defines functions for manipulating a _Red-Black Tree_.
 *
 * @sa [Red-Black Tree](https://en.wikipedia.org/wiki/Red-black_tree)
 */

// local
#include "pjl_config.h"                 /* must go first */
/// @cond DOXYGEN_IGNORE
#define RED_BLACK_H_INLINE _GL_EXTERN_INLINE
/// @endcond
#include "red_black.h"
#include "util.h"

/// @cond DOXYGEN_IGNORE

// standard
#include <assert.h>
#include <stdio.h>                      /* for NULL */
#include <stdlib.h>                     /* or free(3) */

#define RB_FIRST(TREE)            (RB_ROOT(TREE)->child[RB_L])
#define RB_NIL(TREE)              (&(TREE)->nil)
#define RB_ROOT(TREE)             (&(TREE)->root)

/// @endcond

/**
 * Red-black tree child direction.
 */
enum rb_dir {
  RB_L,                                 ///< Left child direction.
  RB_R                                  ///< Right child direction.
};
typedef enum rb_dir rb_dir_t;

///////////////////////////////////////////////////////////////////////////////

// local functions
static void rb_tree_rotate_node( rb_tree_t*, rb_node_t*, rb_dir_t );

////////// inline functions ///////////////////////////////////////////////////

/**
 * Convenience function for checking that a node is black.
 *
 * @param node A pointer to the rb_node to check.
 * @return Returns `true` only if \a node is black.
 *
 * @sa is_red()
 */
PJL_WARN_UNUSED_RESULT
static inline bool is_black( rb_node_t const *node ) {
  return node->color == RB_BLACK;
}

/**
 * Convenience function for checking whether a node is the left or right child
 * of its parent.
 *
 * @param node A pointer to the rb_node to check.
 * @param dir The direction to check for.
 * @return Returns `true` only if \a node is the \a dir child of its parent.
 */
PJL_WARN_UNUSED_RESULT
static inline bool is_dir( rb_node_t const *node, rb_dir_t dir ) {
  return node == node->parent->child[dir];
}

/**
 * Convenience function for checking that a node is red.
 *
 * @param node A pointer to the rb_node to check.
 * @return Returns `true` only if \a node is red.
 *
 * @sa is_black()
 */
PJL_WARN_UNUSED_RESULT
static inline bool is_red( rb_node_t const *node ) {
  return node->color == RB_RED;
}

////////// local functions ////////////////////////////////////////////////////

/**
 * Frees all memory associated with \a node _including_ \a node itself.
 *
 * @param tree A pointer to the red-black tree to free \a node from.
 * @param node A pointer to the rb_node to free.
 * @param free_fn A pointer to a function used to free data associated with \a
 * node or NULL if unnecessary.
 */
static void rb_node_free( rb_tree_t *tree, rb_node_t *node,
                          rb_free_fn_t free_fn ) {
  assert( node != NULL );

  if ( node != RB_NIL(tree) ) {
    rb_node_free( tree, node->child[RB_L], free_fn );
    rb_node_free( tree, node->child[RB_R], free_fn );
    if ( free_fn != NULL )
      (*free_fn)( node->data );
    free( node );
  }
}

#ifndef NDEBUG
/**
 * Checks that some invariants of \a tree still hold.
 *
 * @param tree A pointer to the red-black tree to check.
 */
static void rb_tree_check( rb_tree_t const *tree ) {
  assert( tree != NULL );
  assert( RB_NIL(tree)->data == NULL );
  assert( RB_NIL(tree)->child[RB_L] == RB_NIL(tree) );
  assert( RB_NIL(tree)->child[RB_R] == RB_NIL(tree) );
  assert( RB_NIL(tree)->parent == RB_NIL(tree) );
  assert( RB_NIL(tree)->color == RB_BLACK );
  assert( RB_FIRST(tree)->color == RB_BLACK );
  assert(
    // If the left child is nil, the right child must not be nil.
    RB_FIRST(tree) != RB_NIL(tree) || RB_ROOT(tree)->child[RB_R] == RB_NIL(tree)
  );
}
#else
#define rb_tree_check(TREE)       do { } while (0)
}
#endif /* NDEBUG */

/**
 * Gets the successor of \a node.
 *
 * @param tree A pointer to the red-black tree that \a node is part of.
 * @param node A pointer to the rb_node to get the successor of.
 * @return Returns said successor.
 */
PJL_WARN_UNUSED_RESULT
static rb_node_t* rb_tree_node_successor( rb_tree_t *tree, rb_node_t *node ) {
  assert( tree != NULL );
  assert( node != NULL );

  rb_node_t *next = node->child[RB_R];

  if ( next != RB_NIL(tree) ) {
    while ( next->child[RB_L] != RB_NIL(tree) )
      next = next->child[RB_L];
  } else {
    // No right child, move up until we find it or hit the root.
    for ( next = node->parent; node == next->child[RB_R]; next = next->parent )
      node = next;
    if ( next == RB_ROOT(tree) )
      next = RB_NIL(tree);
  }
  return next;
}

/**
 * Repairs the tree after a node has been deleted by rotating and repainting
 * colors to restore the 4 properties inherent in red-black trees.
 *
 * @param tree A pointer to the red-black tree to repair.
 * @param node A pointer to the rb_node to start the repair at.
 */
static void rb_tree_repair_node( rb_tree_t *tree, rb_node_t *node ) {
  assert( tree != NULL );
  assert( node != NULL );

  while ( is_black( node ) ) {
    rb_dir_t const dir = STATIC_CAST( rb_dir_t, is_dir( node->parent, RB_R ) );
    rb_node_t *sibling = node->parent->child[dir];
    if ( is_red( sibling ) ) {
      sibling->color = RB_BLACK;
      node->parent->color = RB_RED;
      rb_tree_rotate_node( tree, node->parent, !dir );
      sibling = node->parent->child[dir];
    }
    if ( is_red( sibling->child[RB_L] ) || is_red( sibling->child[RB_R] ) ) {
      if ( is_black( sibling ) ) {
        sibling->child[!dir]->color = RB_BLACK;
        sibling->color = RB_RED;
        rb_tree_rotate_node( tree, sibling, dir );
        sibling = node->parent->child[dir];
      }
      sibling->color = node->parent->color;
      node->parent->color = RB_BLACK;
      sibling->child[dir]->color = RB_BLACK;
      rb_tree_rotate_node( tree, node->parent, !dir );
      break;
    }
    sibling->color = RB_RED;
    node = node->parent;
  } // while
}

/**
 * Resets \a tree to empty.
 *
 * @param tree A pointer to the red-black tree to reset.
 *
 * @warning Unlike rb_tree_cleanup(), this function does _not_ free nodes of a
 * non-empty tree.  This function is to be used only on new (empty) trees or on
 * newly cleaned-up (now empty) trees.
 *
 * @sa rb_tree_cleanup()
 * @sa rb_tree_init()
 */
static void rb_tree_reset( rb_tree_t *tree ) {
  assert( tree != NULL );

  tree->nil = (rb_node_t){
    .data = NULL,
    .child = { RB_NIL(tree), RB_NIL(tree) },
    .parent = RB_NIL(tree),
    .color = RB_BLACK
  };

  *RB_ROOT(tree) = *RB_NIL(tree);
  tree->cmp_fn = NULL;
}

/**
 * Rotates a subtree of a red-black tree.
 *
 * @param tree A pointer to the red-black tree to manipulate.
 * @param node A pointer to the rb_node to rotate.
 * @param dir The direction to rotate.
 */
static void rb_tree_rotate_node( rb_tree_t *tree, rb_node_t *node,
                                 rb_dir_t dir ) {
  assert( tree != NULL );
  assert( node != NULL );

  rb_node_t *const temp = node->child[!dir];
  node->child[!dir] = temp->child[dir];

  if ( temp->child[dir] != RB_NIL(tree) )
    temp->child[dir]->parent = node;
  temp->parent = node->parent;
  node->parent->child[ is_dir( node, RB_R ) ] = temp;
  temp->child[dir] = node;
  node->parent = temp;
  rb_tree_check( tree );
}

/**
 * Performs an in-order traversal of the red-black tree starting at \a node.
 *
 * @param tree A pointer to the red-black tree to visit.
 * @param node A pointer to the rb_node to start visiting at.
 * @param visit_fn The visitor function to use.
 * @param v_data Optional data passed to \a visit_fn.
 * @return Returns a pointer to the rb_node at which visiting stopped or NULL
 * if the entire sub-tree was visited.
 */
PJL_WARN_UNUSED_RESULT
static rb_node_t* rb_tree_visit_node( rb_tree_t const *tree, rb_node_t *node,
                                      rb_visit_fn_t visit_fn, void *v_data ) {
  assert( tree != NULL );
  assert( node != NULL );

  while ( node != RB_NIL(tree) ) {
    rb_node_t *const stopped_node =
      rb_tree_visit_node( tree, node->child[RB_L], visit_fn, v_data );
    if ( stopped_node != NULL )
      return stopped_node;
    if ( (*visit_fn)( node->data, v_data ) )
      return node;
    node = node->child[RB_R];
  } // while

  return NULL;
}

////////// extern functions ///////////////////////////////////////////////////

void rb_tree_cleanup( rb_tree_t *tree, rb_free_fn_t free_fn ) {
  if ( tree != NULL ) {
    rb_node_free( tree, RB_FIRST(tree), free_fn );
    rb_tree_reset( tree );
  }
}

void* rb_tree_delete( rb_tree_t *tree, rb_node_t *delete ) {
  assert( tree != NULL );
  assert( delete != NULL );
  assert( delete != RB_NIL(tree) );

  void *const data = delete->data;

  rb_node_t *const surrogate =
    delete->child[RB_L] == RB_NIL(tree) || delete->child[RB_R] == RB_NIL(tree) ?
      delete :
      rb_tree_node_successor( tree, delete );

  rb_node_t *const non_nil_child =
    surrogate->child[ surrogate->child[RB_L] == RB_NIL(tree) ];

  if ( surrogate->parent == RB_ROOT(tree) ) {
    non_nil_child->parent = surrogate->parent;
    RB_FIRST(tree) = non_nil_child;
  } else {
    surrogate->parent->child[ is_dir( surrogate, RB_R ) ] = non_nil_child;
  }

  if ( is_black( surrogate ) )
    rb_tree_repair_node( tree, non_nil_child );

  if ( surrogate != delete ) {
    surrogate->color = delete->color;
    surrogate->child[RB_L] = delete->child[RB_L];
    surrogate->child[RB_R] = delete->child[RB_R];
    surrogate->parent = delete->parent;
    delete->child[RB_L]->parent = delete->child[RB_R]->parent = surrogate;
    delete->parent->child[ is_dir( delete, RB_R ) ] = surrogate;
  }

  free( delete );
  RB_FIRST(tree)->color = RB_BLACK;     // first node is always black
  rb_tree_check( tree );
  return data;
}

rb_node_t* rb_tree_find( rb_tree_t const *tree, void const *data ) {
  assert( tree != NULL );
  assert( data != NULL );

  for ( rb_node_t *node = RB_FIRST(tree); node != RB_NIL(tree); ) {
    int const cmp = (*tree->cmp_fn)( data, node->data );
    if ( cmp == 0 )
      return node;
    node = node->child[ cmp > 0 ];
  } // for
  return NULL;
}

void rb_tree_init( rb_tree_t *tree, rb_cmp_fn_t cmp_fn ) {
  assert( tree != NULL );
  assert( cmp_fn != NULL );
  rb_tree_reset( tree );
  tree->cmp_fn = cmp_fn;
}

rb_insert_rv_t rb_tree_insert( rb_tree_t *tree, void *data ) {
  assert( tree != NULL );
  assert( data != NULL );

  rb_node_t *node = RB_FIRST(tree);
  rb_node_t *parent = RB_ROOT(tree);

  //
  // Find either the existing node having the same data -OR- the parent for the
  // new node.
  //
  while ( node != RB_NIL(tree) ) {
    int const cmp = (*tree->cmp_fn)( data, node->data );
    if ( cmp == 0 )
      return (rb_insert_rv_t){ node, false };
    parent = node;
    node = node->child[ cmp > 0 ];
  } // while

  node = MALLOC( rb_node_t, 1 );
  *node = (rb_node_t){
    .data = data,
    .child = { RB_NIL(tree), RB_NIL(tree) },
    .parent = parent,
    .color = RB_RED
  };
  rb_insert_rv_t const rv = (rb_insert_rv_t){ node, true };

  // Determine which child of the parent the new node should be.
  rb_dir_t dir = STATIC_CAST( rb_dir_t,
    parent != RB_ROOT(tree) && (*tree->cmp_fn)( data, parent->data ) > 0
  );
  assert( parent->child[dir] == RB_NIL(tree) );
  parent->child[dir] = node;

  //
  // If the parent node is black, we're all set; if it's red, we have the
  // following possible cases to deal with.  We iterate through the rest of the
  // tree to make sure none of the required properties is violated.
  //
  //  1. The uncle is red.  We repaint both the parent and uncle black and
  //     repaint the grandparent node red.
  //
  //  2. The uncle is black and the new node is the right child of its parent,
  //     and the parent in turn is the left child of its parent.  We do a left
  //     rotation to switch the roles of the parent and child, relying on
  //     further iterations to fixup the old parent.
  //
  //  3. The uncle is black and the new node is the left child of its parent,
  //     and the parent in turn is the left child of its parent.  We switch the
  //     colors of the parent and grandparent and perform a right rotation
  //     around the grandparent.  This makes the former parent the parent of
  //     the new node and the former grandparent.
  //
  // Note that because we use a sentinel for the root node we never need to
  // worry about replacing the root.
  //
  while ( is_red( node->parent ) ) {
    dir = STATIC_CAST( rb_dir_t, is_dir( node->parent, RB_R ) );
    rb_node_t *const uncle = node->parent->parent->child[dir];
    if ( is_red( uncle ) ) {
      node->parent->color = RB_BLACK;
      uncle->color = RB_BLACK;
      node->parent->parent->color = RB_RED;
      node = node->parent->parent;
      continue;
    }
    if ( is_dir( node, dir ) ) {
      node = node->parent;
      rb_tree_rotate_node( tree, node, !dir );
    }
    node->parent->color = RB_BLACK;
    node->parent->parent->color = RB_RED;
    rb_tree_rotate_node( tree, node->parent->parent, dir );
  } // while

  RB_FIRST(tree)->color = RB_BLACK;     // first node is always black
  rb_tree_check( tree );
  return rv;
}

rb_node_t* rb_tree_visit( rb_tree_t const *tree, rb_visit_fn_t visit_fn,
                          void *v_data ) {
  assert( visit_fn != NULL );

  rb_tree_t *const nonconst_tree = CONST_CAST( rb_tree_t*, tree );
  return rb_tree_visit_node(
    nonconst_tree, RB_FIRST(nonconst_tree), visit_fn, v_data
  );
}

///////////////////////////////////////////////////////////////////////////////
/* vim:set et sw=2 ts=2: */
