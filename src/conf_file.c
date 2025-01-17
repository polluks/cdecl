/*
**      cdecl -- C gibberish translator
**      src/conf_file.c
**
**      Copyright (C) 2017-2023  Paul J. Lucas, et al.
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
 * Defines functions for reading **cdecl**'s configuration file.
 */

// local
#include "pjl_config.h"                 /* must go first */
#include "conf_file.h"
#include "cdecl.h"
#include "options.h"
#include "parse.h"
#include "print.h"
#include "strbuf.h"
#include "util.h"

/// @cond DOXYGEN_IGNORE

// standard
#include <assert.h>
#include <errno.h>
#if HAVE_PWD_H
# include <pwd.h>                       /* for getpwuid() */
#endif /* HAVE_PWD_H */
#include <stdio.h>
#include <stdlib.h>
#include <sysexits.h>
#include <unistd.h>                     /* for geteuid() */

/// @endcond

/**
 * @ingroup conf-file-group
 * @{
 */

////////// local functions ////////////////////////////////////////////////////

/**
 * Gets the full path of the user's home directory.
 *
 * @return Returns said directory or NULL if it is not obtainable.
 */
NODISCARD
static char const* home_dir( void ) {
  static char const *home;

  RUN_ONCE {
    home = null_if_empty( getenv( "HOME" ) );
#if HAVE_GETEUID && HAVE_GETPWUID && HAVE_STRUCT_PASSWD_PW_DIR
    if ( home == NULL ) {
      struct passwd *const pw = getpwuid( geteuid() );
      if ( pw != NULL )
        home = null_if_empty( pw->pw_dir );
    }
#endif /* HAVE_GETEUID && && HAVE_GETPWUID && HAVE_STRUCT_PASSWD_PW_DIR */
  }

  return home;
}

/**
 * Reads the configuration file \a conf_path.
 *
 * @param conf_path The full path of the configuration file to read.
 * @return Returns `false` only if \a conf_path could not be opened for
 * reading.
 */
NODISCARD
static bool read_conf_file( char const *conf_path ) {
  assert( conf_path != NULL );

  FILE *const conf_file = fopen( conf_path, "r" );
  if ( conf_file == NULL )
    return false;

  PJL_IGNORE_RV( cdecl_parse_file( conf_file ) );
  PJL_IGNORE_RV( fclose( conf_file ) );
  return true;
}

////////// extern functions ///////////////////////////////////////////////////

void conf_init( void ) {
  ASSERT_RUN_ONCE();

  char const *conf_path = opt_conf_path;
  if ( conf_path == NULL )
    conf_path = null_if_empty( getenv( "CDECLRC" ) );

  strbuf_t sbuf;
  strbuf_init( &sbuf );

  if ( conf_path == NULL ) {
    char const *const home = home_dir();
    if ( home != NULL ) {
      strbuf_puts( &sbuf, home );
      strbuf_paths( &sbuf, "." CONF_FILE_NAME_DEFAULT );
      conf_path = sbuf.str;
    }
  }

  if ( conf_path != NULL ) {
    print_params.conf_path = conf_path;
    if ( !read_conf_file( conf_path ) && opt_conf_path != NULL )
      fatal_error( EX_NOINPUT, "%s: %s\n", conf_path, STRERROR() );
    print_params.conf_path = NULL;
    strbuf_cleanup( &sbuf );
  }
}

///////////////////////////////////////////////////////////////////////////////

/** @} */

/* vim:set et sw=2 ts=2: */
