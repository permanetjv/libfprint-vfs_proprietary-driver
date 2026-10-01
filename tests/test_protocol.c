#include <glib.h>

#include "protocol.h"

static void
assert_metadata (gint     width,
                 gint     height,
                 gint     length,
                 gboolean expected)
{
  struct capture_helper_api_img_metadata metadata = {
    .img_len = length,
    .img_w = width,
    .img_h = height,
  };
  gsize pixels = 0;

  g_assert_cmpint (vfs_proprietary_validate_metadata (&metadata, &pixels), ==,
                   expected);
  if (expected)
    g_assert_cmpuint (pixels, ==, (gsize) length);
}

static void
test_valid_metadata (void)
{
  assert_metadata (256, 360, 256 * 360, TRUE);
  assert_metadata (1023, 1023, 1023 * 1023, TRUE);
}

static void
test_length_mismatch (void)
{
  assert_metadata (256, 360, 256 * 360 - 1, FALSE);
  assert_metadata (256, 360, 256 * 360 + 1, FALSE);
}

static void
test_invalid_dimensions (void)
{
  assert_metadata (0, 360, 0, FALSE);
  assert_metadata (-1, 360, 1, FALSE);
  assert_metadata (1024, 1, 1024, FALSE);
  assert_metadata (1, 1024, 1024, FALSE);
}

static void
test_invalid_length (void)
{
  assert_metadata (1, 1, 0, FALSE);
  assert_metadata (1, 1, -1, FALSE);
}

int
main (int argc, char **argv)
{
  g_test_init (&argc, &argv, NULL);
  g_test_add_func ("/vfs-proprietary/protocol/valid", test_valid_metadata);
  g_test_add_func ("/vfs-proprietary/protocol/length-mismatch", test_length_mismatch);
  g_test_add_func ("/vfs-proprietary/protocol/dimensions", test_invalid_dimensions);
  g_test_add_func ("/vfs-proprietary/protocol/length", test_invalid_length);
  return g_test_run ();
}
