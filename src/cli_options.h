/*
**      cdecl -- C gibberish translator
**      src/cli_options.h
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

#ifndef cdecl_cli_options_H
#define cdecl_cli_options_H

/**
 * @file
 * Declares global variables and functions for command-line options.
 */

// local
#include "pjl_config.h"                 /* must go first */

/// @cond DOXYGEN_IGNORE

// standard
#include <getopt.h>

/// @endcond

///////////////////////////////////////////////////////////////////////////////

/**
 * @defgroup cli-options-group Command-Line Options
 * Declares global variables and functions for command-line options.
 *
 * @sa \ref cdecl-options-group
 * @sa \ref set-options-group
 *
 * @{
 */

/**
 * Convenience macro for iterating over all cdecl command-line options.
 *
 * @param VAR The `struct option` loop variable.
 *
 * @sa cli_option_next()
 * @sa #FOREACH_SET_OPTION()
 */
#define FOREACH_CLI_OPTION(VAR) \
  for ( struct option const *VAR = NULL; (VAR = cli_option_next( VAR )) != NULL; )

////////// extern functions ///////////////////////////////////////////////////

/**
 * Iterates to the next cdecl command-line option.
 *
 * @note This function isn't normally called directly; use the
 * #FOREACH_CLI_OPTION() macro instead.
 *
 * @param opt A pointer to the previous option. For the first iteration, NULL
 * should be passed.
 * @return Returns the next command-line option or NULL for none.
 *
 * @sa #FOREACH_CLI_OPTION()
 */
PJL_WARN_UNUSED_RESULT
struct option const* cli_option_next( struct option const *opt );

/**
 * Initializes cdecl options from the command-line.
 * On return, `*pargc` and `*pargv` are updated to reflect the remaining
 * command-line with the options removed.
 *
 * @param pargc A pointer to the argument count from main().
 * @param pargv A pointer to the argument values from main().
 */
void cli_options_init( int *pargc, char const **pargv[] );

///////////////////////////////////////////////////////////////////////////////

/** @} */

#endif /* cdecl_cli_options_H */
/* vim:set et sw=2 ts=2: */