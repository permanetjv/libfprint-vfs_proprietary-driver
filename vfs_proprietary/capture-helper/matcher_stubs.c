/*
 * Copyright 2026 Jacob Vanderford
 *
 * This library is free software; you can redistribute it and/or modify it
 * under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation; either version 2.1 of the License, or (at
 * your option) any later version.
 */

/*
 * HP's fingerprint wrapper imports the matcher-open entry points even when it
 * is used only to capture an image for libfprint.  The optional proprietary
 * matcher libraries are not distributed with the HP SoftPaq.  Returning
 * success here selects the wrapper's image-only path; template extraction and
 * matching remain libfprint's responsibility.
 *
 * These symbols must be exported by the capture-helper executable so the
 * dynamic loader can resolve the legacy wrapper's imports.
 */
int mssAdaptiveMatcherOpen (void);
int mssCogentOpen (void);
int mssDpOpen (void);
int mssFingercellOpen (void);

int
mssAdaptiveMatcherOpen (void)
{
  return 0;
}

int
mssCogentOpen (void)
{
  return 0;
}

int
mssDpOpen (void)
{
  return 0;
}

int
mssFingercellOpen (void)
{
  return 0;
}
