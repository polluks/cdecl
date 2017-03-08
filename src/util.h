/*
**      cdecl -- C gibberish translator
**      src/util.h
**
**      Paul J. Lucas
*/

#ifndef cdecl_util_H
#define cdecl_util_H

/**
 * @file
 * Contains utility constants, macros, and functions.
 */

// local
#include "config.h"                     /* must go first */

// standard
#include <stdbool.h>
#include <stddef.h>                     /* for size_t */
#include <stdio.h>                      /* for FILE */
#include <string.h>
#include <sysexits.h>

_GL_INLINE_HEADER_BEGIN
#ifndef CDECL_UTIL_INLINE
# define CDECL_UTIL_INLINE _GL_INLINE
#endif /* CDECL_UTIL_INLINE */

///////////////////////////////////////////////////////////////////////////////

#define ARRAY_SIZE(A)             (sizeof(A) / sizeof(A[0]))
#define BLOCK(...)                do { __VA_ARGS__ } while (0)
#define FREE(PTR)                 free( (void*)(PTR) )
#define NO_OP                     ((void)0)
#define PERROR_EXIT(STATUS)       BLOCK( perror( me ); exit( STATUS ); )
#define PRINT_ERR(...)            fprintf( stderr, __VA_ARGS__ )
#define STRERROR                  strerror( errno )

#define INTERNAL_ERR(FORMAT,...) \
  PMESSAGE_EXIT( EX_SOFTWARE, "internal error: " FORMAT, __VA_ARGS__ )

#define MALLOC(TYPE,N) \
  (TYPE*)check_realloc( NULL, sizeof(TYPE) * (N) )

#define PMESSAGE_EXIT(STATUS,FORMAT,...) \
  BLOCK( PRINT_ERR( "%s: " FORMAT, me, __VA_ARGS__ ); exit( STATUS ); )

#define FERROR(STREAM) \
  BLOCK( if ( ferror( STREAM ) ) PERROR_EXIT( EX_IOERR ); )

#define FPRINTF(STREAM,...) \
  BLOCK( if ( fprintf( (STREAM), __VA_ARGS__ ) < 0 ) PERROR_EXIT( EX_IOERR ); )

#define FPUTC(C,STREAM) \
  BLOCK( if ( putc( (C), (STREAM) ) == EOF ) PERROR_EXIT( EX_IOERR ); )

#define FPUTS(S,STREAM) \
  BLOCK( if ( fputs( (S), (STREAM) ) == EOF ) PERROR_EXIT( EX_IOERR ); )

#define FSTAT(FD,STAT) \
  BLOCK( if ( fstat( (FD), (STAT) ) < 0 ) PERROR_EXIT( EX_IOERR ); )

///////////////////////////////////////////////////////////////////////////////

typedef struct link link_t;

/**
 * A simple \c struct that serves as a "base class" for an intrusive singly
 * linked list. A "derived class" \e must be a \c struct that has a "next"
 * pointer as its first member.
 */
struct link {
  link_t *next;
};

////////// extern functions ///////////////////////////////////////////////////

/**
 * Extracts the base portion of a path-name.
 * Unlike \c basename(3):
 *  + Trailing \c '/' characters are not deleted.
 *  + \a path_name is never modified (hence can therefore be \c const).
 *  + Returns a pointer within \a path_name (hence is multi-call safe).
 *
 * @param path_name The path-name to extract the base portion of.
 * @return Returns a pointer to the last component of \a path_name.
 * If \a path_name consists entirely of '/' characters,
 * a pointer to the string "/" is returned.
 */
char const* base_name( char const *path_name );

/**
 * Calls \c realloc(3) and checks for failure.
 * If reallocation fails, prints an error message and exits.
 *
 * @param p The pointer to reallocate.  If NULL, new memory is allocated.
 * @param size The number of bytes to allocate.
 * @return Returns a pointer to the allocated memory.
 */
void* check_realloc( void *p, size_t size );

/**
 * Calls \c strdup(3) and checks for failure.
 * If memory allocation fails, prints an error message and exits.
 *
 * @param s The null-terminated string to duplicate or null.
 * @return Returns a copy of \a s or null if \a s is null.
 */
char* check_strdup( char const *s );

/**
 * Checks the flag: if \c false, sets it to \c true.
 *
 * @param flag A pointer to the Boolean flag to be tested and, if \c false,
 * sets it to \c true.
 * @return Returns \c true only if \c *flag is \c false initially.
 */
CDECL_UTIL_INLINE bool false_set( bool *flag ) {
  return !*flag && (*flag = true);
}

#ifndef HAVE_FMEMOPEN
/**
 * Local implementation of POSIX 2008 fmemopen(3) for systems that don't have
 * it.
 *
 * @param buf A pointer to the buffer to use.  The pointer must remain valid
 * for as along as the FILE is open.
 * @param size The size of \a buf.
 * @param mode The open mode.  It \e must contain \c r.
 * @return Returns a FILE containing the contents of \a buf.
 */
FILE* fmemopen( void const *buf, size_t size, char const *mode );
#endif /* HAVE_FMEMOPEN */

/**
 * Adds a pointer to the head of the free-later-list.
 *
 * @param p The pointer to add.
 * @return Returns \a p.
 */
void* free_later( void *p );

/**
 * Frees all the memory pointed to by all the nodes in the free-later-list.
 */
void free_now( void );

/**
 * Checks whether \a s is a blank line, that is a line consisting only of
 * whitespace.
 *
 * @param s The null-terminated string to check.
 * @return Returns \c true only if \a s is a blank line.
 */
CDECL_UTIL_INLINE bool is_blank_line( char const *s ) {
  s += strspn( s, " \t\r\n" );
  return !*s;
}

/**
 * Checks whether the given file descriptor refers to a regular file.
 *
 * @param fd The file descriptor to check.
 * @return Returns \c true only if \a fd refers to a regular file.
 */
bool is_file( int fd );

/**
 * Prints a key/value pair as JSON.
 *
 * @param key The key to print.
 * @param value The value to print, if any.  If either null or the empty
 * string, \c null is printed instead of the value.
 * @param jout The FILE to print to.
 */
void json_print_kv( char const *key, char const *value, FILE *jout );

/**
 * Wraps GNU readline(3) by:
 *
 *  + Adding non-whitespace-only lines to the history.
 *  + Returning only non-whitespace-only lines.
 *  + Ensuring every line returned ends with a newline.
 *
 * If readline(3) is not compiled in, uses getline(3).
 *
 * @return Returns the line read or null for EOF.
 */
char* readline_wrapper( void );

/**
 * Pops a node from the head of a list.
 *
 * @param phead The pointer to the pointer to the head of the list.
 * @return Returns the popped node or null if the list is empty.
 */
link_t* link_pop( link_t **phead );

/**
 * Convenience macro that pops a node from the head of a list and does the
 * necessary casting.
 *
 * @param NODE_TYPE The type of the node.
 * @param PHEAD A pointer to the pointer of the head of the list.
 * @return Returns the popped node or null if the list is empty.
 * @hideinitializer
 */
#define LINK_POP(NODE_TYPE,PHEAD) \
  (NODE_TYPE*)link_pop( (link_t**)(PHEAD) )

/**
 * Pushes a node onto the front of a list.
 *
 * @param phead The pointer to the pointer to the head of the list.  The head
 * is updated to point to \a node.
 * @param node The pointer to the node to add.  Its \c next pointer is set to
 * the old head of the list.
 */
void link_push( link_t **phead, link_t *node );

/**
 * Convenience macro that pushes a node onto the front of a list and does the
 * necessary casting.
 *
 * @param PHEAD The pointer to the pointer to the head of the list.  The head
 * is updated to point to \a NODE.
 * @param NODE The pointer to the node to add.  Its \c next pointer is set to
 * the old head of the list.
 * @hideinitializer
 */
#define LINK_PUSH(PHEAD,NODE) \
  link_push( (link_t**)(PHEAD), (link_t*)(NODE) )

/**
 * A variant of strcpy(3) that returns the number of characters copied.
 *
 * @param dst A pointer to receive the copy of \a src.
 * @param src The null-terminated string to copy.
 * @return Returns the number of characters copied.
 */
size_t strcpy_len( char *dst, char const *src );

/**
 * Checks the flag: if \c false, sets it to \c true.
 *
 * @param flag A pointer to the Boolean flag to be tested and, if \c false,
 * sets it to \c true.
 * @return Returns \c true only if \c *flag is \c true initially.
 */
CDECL_UTIL_INLINE bool true_or_set( bool *flag ) {
  return *flag || !(*flag = true);
}

///////////////////////////////////////////////////////////////////////////////

#endif /* cdecl_util_H */
/* vim:set et sw=2 ts=2: */
