#include "protocol.h"
#include "vfs_proprietary.h"

gboolean
vfs_proprietary_validate_metadata (
  const struct capture_helper_api_img_metadata *metadata,
  gsize                                         *pixels)
{
  guint64 pixel_count;

  g_return_val_if_fail (metadata != NULL, FALSE);

  if (metadata->img_w <= 0 || metadata->img_h <= 0 ||
      metadata->img_w > VFS_PROPRIETARY_IMG_MAX_DIMENSION ||
      metadata->img_h > VFS_PROPRIETARY_IMG_MAX_DIMENSION ||
      metadata->img_len <= 0)
    return FALSE;

  pixel_count = (guint64) metadata->img_w * (guint64) metadata->img_h;
  if ((guint64) metadata->img_len != pixel_count || pixel_count > G_MAXSIZE)
    return FALSE;

  if (pixels)
    *pixels = (gsize) pixel_count;
  return TRUE;
}
