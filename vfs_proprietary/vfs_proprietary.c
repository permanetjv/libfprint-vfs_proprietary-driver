/*
 * Copyright 2016, 2018 Jan Chren (rindeal)
 * Copyright 2026 Jacob Vanderford
 *
 * This library is free software; you can redistribute it and/or modify it
 * under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation; either version 2.1 of the License, or (at
 * your option) any later version.
 */

#define FP_COMPONENT "vfs_proprietary"

#include "drivers_api.h"
#include "fpi-image.h"
#include "vfs_proprietary.h"
#include "capture-helper/api.h"
#include "protocol.h"

#include <errno.h>
#include <fcntl.h>
#include <gio/gunixinputstream.h>
#include <glib-unix.h>
#include <unistd.h>

#ifndef VFS_PROPRIETARY_CAPTURE_HELPER_PATH
#define VFS_PROPRIETARY_CAPTURE_HELPER_PATH "vfs_proprietary-capture-helper"
#endif

enum
{
  CHILD_IMG_READY_FD = 3,
  CHILD_IMG_META_FD = 4,
  CHILD_IMG_DATA_FD = 5,
};

struct _FpiDeviceVfsProprietary
{
  FpImageDevice parent;

  GSubprocess  *process;
  GInputStream *ready_stream;
  GInputStream *meta_stream;
  GInputStream *data_stream;
  GCancellable *io_cancel;
  FpImage      *image;
  GError       *protocol_error;

  struct capture_helper_api_img_ready    ready;
  struct capture_helper_api_img_metadata metadata;

  gboolean active;
  gboolean image_delivered;
};

G_DECLARE_FINAL_TYPE (FpiDeviceVfsProprietary, fpi_device_vfs_proprietary,
                      FPI, DEVICE_VFS_PROPRIETARY, FpImageDevice)
G_DEFINE_TYPE (FpiDeviceVfsProprietary, fpi_device_vfs_proprietary,
               FP_TYPE_IMAGE_DEVICE)

G_STATIC_ASSERT (sizeof (struct capture_helper_api_img_ready) == 8);
G_STATIC_ASSERT (sizeof (struct capture_helper_api_img_metadata) == 12);

static void
close_fd (gint *fd)
{
  if (*fd >= 0)
    close (*fd);
  *fd = -1;
}

static void
vfs_proprietary_stop (FpiDeviceVfsProprietary *self)
{
  if (self->io_cancel)
    g_cancellable_cancel (self->io_cancel);
  if (self->process)
    g_subprocess_force_exit (self->process);
}

static void
vfs_proprietary_protocol_fail (FpiDeviceVfsProprietary *self,
                               GError                   *error)
{
  if (!self->protocol_error)
    self->protocol_error = error;
  else
    g_error_free (error);

  vfs_proprietary_stop (self);
}

static GError *
read_error (const gchar *field,
            gsize        expected,
            gsize        actual,
            GError      *cause)
{
  GError *error;

  if (cause)
    error = fpi_device_error_new_msg (FP_DEVICE_ERROR_PROTO,
                                      "capture helper %s read failed after %zu/%zu bytes: %s",
                                      field, actual, expected, cause->message);
  else
    error = fpi_device_error_new_msg (FP_DEVICE_ERROR_PROTO,
                                      "capture helper closed %s after %zu/%zu bytes",
                                      field, actual, expected);
  g_clear_error (&cause);
  return error;
}

static void image_data_read_cb (GObject *, GAsyncResult *, gpointer);
static void image_metadata_read_cb (GObject *, GAsyncResult *, gpointer);

static void
image_ready_read_cb (GObject      *source,
                     GAsyncResult *result,
                     gpointer      user_data)
{
  FpiDeviceVfsProprietary *self = user_data;
  g_autoptr(GError) error = NULL;
  gsize bytes_read = 0;

  if (!g_input_stream_read_all_finish (G_INPUT_STREAM (source), result,
                                       &bytes_read, &error))
    {
      if (!g_error_matches (error, G_IO_ERROR, G_IO_ERROR_CANCELLED))
        vfs_proprietary_protocol_fail (self,
                                       read_error ("ready marker", sizeof (self->ready),
                                                   bytes_read, g_steal_pointer (&error)));
      g_object_unref (self);
      return;
    }
  if (bytes_read != sizeof (self->ready))
    {
      vfs_proprietary_protocol_fail (self,
                                     read_error ("ready marker", sizeof (self->ready),
                                                 bytes_read, NULL));
      g_object_unref (self);
      return;
    }
  if (self->ready.status != CAPTURE_HELPER_IMG_READY_OK)
    {
      vfs_proprietary_protocol_fail (
        self,
        fpi_device_error_new_msg (FP_DEVICE_ERROR_PROTO,
                                  "capture helper returned an invalid ready marker"));
      g_object_unref (self);
      return;
    }

  fpi_image_device_report_finger_status (FP_IMAGE_DEVICE (self), TRUE);
  g_input_stream_read_all_async (self->meta_stream,
                                 &self->metadata, sizeof (self->metadata),
                                 G_PRIORITY_DEFAULT, self->io_cancel,
                                 image_metadata_read_cb, g_object_ref (self));
  g_object_unref (self);
}

static void
image_metadata_read_cb (GObject      *source,
                        GAsyncResult *result,
                        gpointer      user_data)
{
  FpiDeviceVfsProprietary *self = user_data;
  g_autoptr(GError) error = NULL;
  gsize pixels;
  gsize bytes_read = 0;

  if (!g_input_stream_read_all_finish (G_INPUT_STREAM (source), result,
                                       &bytes_read, &error))
    {
      if (!g_error_matches (error, G_IO_ERROR, G_IO_ERROR_CANCELLED))
        vfs_proprietary_protocol_fail (self,
                                       read_error ("metadata", sizeof (self->metadata),
                                                   bytes_read, g_steal_pointer (&error)));
      g_object_unref (self);
      return;
    }
  if (bytes_read != sizeof (self->metadata))
    {
      vfs_proprietary_protocol_fail (self,
                                     read_error ("metadata", sizeof (self->metadata),
                                                 bytes_read, NULL));
      g_object_unref (self);
      return;
    }

  if (!vfs_proprietary_validate_metadata (&self->metadata, &pixels))
    {
      vfs_proprietary_protocol_fail (
        self,
        fpi_device_error_new_msg (FP_DEVICE_ERROR_DATA_INVALID,
                                  "invalid capture metadata: width=%d height=%d length=%d",
                                  self->metadata.img_w, self->metadata.img_h,
                                  self->metadata.img_len));
      g_object_unref (self);
      return;
    }

  self->image = fp_image_new (self->metadata.img_w, self->metadata.img_h);
  self->image->flags = FPI_IMAGE_COLORS_INVERTED | FPI_IMAGE_V_FLIPPED;
  g_input_stream_read_all_async (self->data_stream,
                                 self->image->data, pixels,
                                 G_PRIORITY_DEFAULT, self->io_cancel,
                                 image_data_read_cb, g_object_ref (self));
  g_object_unref (self);
}

static void
image_data_read_cb (GObject      *source,
                    GAsyncResult *result,
                    gpointer      user_data)
{
  FpiDeviceVfsProprietary *self = user_data;
  g_autoptr(GError) error = NULL;
  gsize expected = (gsize) self->metadata.img_len;
  gsize bytes_read = 0;

  if (!g_input_stream_read_all_finish (G_INPUT_STREAM (source), result,
                                       &bytes_read, &error))
    {
      if (!g_error_matches (error, G_IO_ERROR, G_IO_ERROR_CANCELLED))
        vfs_proprietary_protocol_fail (self,
                                       read_error ("image", expected, bytes_read,
                                                   g_steal_pointer (&error)));
      g_object_unref (self);
      return;
    }
  if (bytes_read != expected)
    {
      vfs_proprietary_protocol_fail (self,
                                     read_error ("image", expected, bytes_read, NULL));
      g_object_unref (self);
      return;
    }

  self->image_delivered = TRUE;
  fpi_image_device_image_captured (FP_IMAGE_DEVICE (self),
                                   g_steal_pointer (&self->image));
  fpi_image_device_report_finger_status (FP_IMAGE_DEVICE (self), FALSE);
  g_object_unref (self);
}

static void
capture_helper_done_cb (GObject      *source,
                        GAsyncResult *result,
                        gpointer      user_data)
{
  FpiDeviceVfsProprietary *self = user_data;
  g_autoptr(GError) wait_error = NULL;
  g_autofree gchar *stdout_text = NULL;
  g_autofree gchar *stderr_text = NULL;
  gboolean communicated;
  gboolean successful;

  communicated = g_subprocess_communicate_utf8_finish (G_SUBPROCESS (source), result,
                                                        &stdout_text, &stderr_text,
                                                        &wait_error);
  successful = communicated && g_subprocess_get_successful (G_SUBPROCESS (source));

  if (stdout_text && *stdout_text)
    fp_dbg ("capture helper stdout: %s", stdout_text);
  if (stderr_text && *stderr_text)
    fp_warn ("capture helper stderr: %s", stderr_text);

  if (self->active && !self->image_delivered)
    {
      GError *error = g_steal_pointer (&self->protocol_error);

      if (!error && !successful)
        error = fpi_device_error_new_msg (
          FP_DEVICE_ERROR_GENERAL,
          "capture helper failed%s%s",
          stderr_text && *stderr_text ? ": " : "",
          stderr_text && *stderr_text ? stderr_text : "");
      if (!error && wait_error &&
          !g_error_matches (wait_error, G_IO_ERROR, G_IO_ERROR_CANCELLED))
        error = fpi_device_error_new_msg (FP_DEVICE_ERROR_GENERAL,
                                          "capture helper wait failed: %s",
                                          wait_error->message);
      if (!error)
        error = fpi_device_error_new_msg (FP_DEVICE_ERROR_PROTO,
                                          "capture helper exited without an image");
      fpi_image_device_session_error (FP_IMAGE_DEVICE (self), error);
    }

  g_clear_object (&self->ready_stream);
  g_clear_object (&self->meta_stream);
  g_clear_object (&self->data_stream);
  g_clear_object (&self->io_cancel);
  g_clear_object (&self->process);
  g_clear_object (&self->image);
  g_clear_error (&self->protocol_error);
  g_object_unref (self);
}

static gboolean
vfs_proprietary_start (FpiDeviceVfsProprietary *self,
                       GError                  **error)
{
  g_autoptr(GSubprocessLauncher) launcher = NULL;
  GOutputStream *helper_stdin;
  const gchar *runtime_library_path;
  struct capture_helper_api_input api_input = {
    .img_ready_fd = CHILD_IMG_READY_FD,
    .img_meta_fd = CHILD_IMG_META_FD,
    .img_data_fd = CHILD_IMG_DATA_FD,
  };
  gint ready_pipe[2] = { -1, -1 };
  gint meta_pipe[2] = { -1, -1 };
  gint data_pipe[2] = { -1, -1 };
  gsize bytes_written = 0;

  if (self->process)
    {
      g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_PENDING,
                           "capture helper is already running");
      return FALSE;
    }

  if (!g_unix_open_pipe (ready_pipe, FD_CLOEXEC, error) ||
      !g_unix_open_pipe (meta_pipe, FD_CLOEXEC, error) ||
      !g_unix_open_pipe (data_pipe, FD_CLOEXEC, error))
    goto fail;

  launcher = g_subprocess_launcher_new (G_SUBPROCESS_FLAGS_STDIN_PIPE |
                                        G_SUBPROCESS_FLAGS_STDOUT_PIPE |
                                        G_SUBPROCESS_FLAGS_STDERR_PIPE);
  runtime_library_path = g_getenv ("VFS_PROPRIETARY_RUNTIME_LIBRARY_PATH");
  if (runtime_library_path && *runtime_library_path)
    g_subprocess_launcher_setenv (launcher, "LD_LIBRARY_PATH",
                                  runtime_library_path, TRUE);
  g_subprocess_launcher_take_fd (launcher, ready_pipe[1], CHILD_IMG_READY_FD);
  ready_pipe[1] = -1;
  g_subprocess_launcher_take_fd (launcher, meta_pipe[1], CHILD_IMG_META_FD);
  meta_pipe[1] = -1;
  g_subprocess_launcher_take_fd (launcher, data_pipe[1], CHILD_IMG_DATA_FD);
  data_pipe[1] = -1;

  self->process = g_subprocess_launcher_spawn (launcher, error,
                                               VFS_PROPRIETARY_CAPTURE_HELPER_PATH,
                                               NULL);
  if (!self->process)
    goto fail;

  helper_stdin = g_subprocess_get_stdin_pipe (self->process);
  if (!g_output_stream_write_all (helper_stdin, &api_input, sizeof (api_input),
                                  &bytes_written, NULL, error) ||
      bytes_written != sizeof (api_input) ||
      !g_output_stream_close (helper_stdin, NULL, error))
    goto fail;

  self->ready_stream = g_unix_input_stream_new (ready_pipe[0], TRUE);
  ready_pipe[0] = -1;
  self->meta_stream = g_unix_input_stream_new (meta_pipe[0], TRUE);
  meta_pipe[0] = -1;
  self->data_stream = g_unix_input_stream_new (data_pipe[0], TRUE);
  data_pipe[0] = -1;
  self->io_cancel = g_cancellable_new ();
  self->image_delivered = FALSE;
  memset (&self->ready, 0, sizeof (self->ready));
  memset (&self->metadata, 0, sizeof (self->metadata));

  g_input_stream_read_all_async (self->ready_stream,
                                 &self->ready, sizeof (self->ready),
                                 G_PRIORITY_DEFAULT, self->io_cancel,
                                 image_ready_read_cb, g_object_ref (self));
  g_subprocess_communicate_utf8_async (self->process, NULL, NULL,
                                       capture_helper_done_cb,
                                       g_object_ref (self));
  return TRUE;

fail:
  close_fd (&ready_pipe[0]);
  close_fd (&ready_pipe[1]);
  close_fd (&meta_pipe[0]);
  close_fd (&meta_pipe[1]);
  close_fd (&data_pipe[0]);
  close_fd (&data_pipe[1]);
  vfs_proprietary_stop (self);
  g_clear_object (&self->process);
  return FALSE;
}

static void
dev_open (FpImageDevice *dev)
{
  fpi_image_device_open_complete (dev, NULL);
}

static void
dev_close (FpImageDevice *dev)
{
  FpiDeviceVfsProprietary *self = FPI_DEVICE_VFS_PROPRIETARY (dev);

  self->active = FALSE;
  vfs_proprietary_stop (self);
  fpi_image_device_close_complete (dev, NULL);
}

static void
dev_activate (FpImageDevice *dev)
{
  FpiDeviceVfsProprietary *self = FPI_DEVICE_VFS_PROPRIETARY (dev);
  g_autoptr(GError) error = NULL;

  self->active = TRUE;
  if (!vfs_proprietary_start (self, &error))
    {
      self->active = FALSE;
      fpi_image_device_activate_complete (dev, g_steal_pointer (&error));
      return;
    }

  fpi_image_device_activate_complete (dev, NULL);
}

static void
dev_deactivate (FpImageDevice *dev)
{
  FpiDeviceVfsProprietary *self = FPI_DEVICE_VFS_PROPRIETARY (dev);

  self->active = FALSE;
  vfs_proprietary_stop (self);
  fpi_image_device_deactivate_complete (dev, NULL);
}

static const FpIdEntry id_table[] = {
  { .vid = VALIDITY_VENDOR_ID, .pid = VALIDITY_PRODUCT_ID_451 },
  { .vid = VALIDITY_VENDOR_ID, .pid = VALIDITY_PRODUCT_ID_471 },
  { .vid = VALIDITY_VENDOR_ID, .pid = VALIDITY_PRODUCT_ID_491 },
  { .vid = VALIDITY_VENDOR_ID, .pid = VALIDITY_PRODUCT_ID_495 },
  { .vid = 0, .pid = 0, .driver_data = 0 },
};

static void
fpi_device_vfs_proprietary_init (FpiDeviceVfsProprietary *self)
{
}

static void
fpi_device_vfs_proprietary_finalize (GObject *object)
{
  FpiDeviceVfsProprietary *self = FPI_DEVICE_VFS_PROPRIETARY (object);

  self->active = FALSE;
  vfs_proprietary_stop (self);
  g_clear_object (&self->ready_stream);
  g_clear_object (&self->meta_stream);
  g_clear_object (&self->data_stream);
  g_clear_object (&self->io_cancel);
  g_clear_object (&self->process);
  g_clear_object (&self->image);
  g_clear_error (&self->protocol_error);

  G_OBJECT_CLASS (fpi_device_vfs_proprietary_parent_class)->finalize (object);
}

static void
fpi_device_vfs_proprietary_class_init (FpiDeviceVfsProprietaryClass *klass)
{
  GObjectClass *object_class = G_OBJECT_CLASS (klass);
  FpDeviceClass *dev_class = FP_DEVICE_CLASS (klass);
  FpImageDeviceClass *img_class = FP_IMAGE_DEVICE_CLASS (klass);

  object_class->finalize = fpi_device_vfs_proprietary_finalize;

  dev_class->id = FP_COMPONENT;
  dev_class->full_name = "Validity Sensors (isolated proprietary acquisition)";
  dev_class->type = FP_DEVICE_TYPE_USB;
  dev_class->id_table = id_table;
  dev_class->scan_type = FP_SCAN_TYPE_SWIPE;
  dev_class->nr_enroll_stages = VFS_PROPRIETARY_NR_ENROLL;

  img_class->img_open = dev_open;
  img_class->img_close = dev_close;
  img_class->activate = dev_activate;
  img_class->deactivate = dev_deactivate;
  img_class->img_width = -1;
  img_class->img_height = -1;
}
