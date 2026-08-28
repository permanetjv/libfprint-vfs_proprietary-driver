#pragma once

#include <glib.h>

#include "capture-helper/api.h"

gboolean vfs_proprietary_validate_metadata (
  const struct capture_helper_api_img_metadata *metadata,
  gsize                                         *pixels);
