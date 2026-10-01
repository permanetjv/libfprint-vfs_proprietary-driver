/*******************************************************************************
 * Copyright 2016, 2018  Jan Chren (rindeal)
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this library; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
 */

#include "api.h"
#include "vfsFprintWrapper.h"
#include "../assert.h"
#include "../likely.h"
#include "../min_max.h"

#include <stdio.h>   /* fprintf, perror, fclose */
#include <stdlib.h>  /* exit */
#include <string.h>  /* strlen */
#include <stdbool.h>
#include <stdarg.h>  /* va_list, va_start, vfprintf, va_end */
#include <time.h>    /* time */

#include <signal.h>  /* signal */
#include <unistd.h>  /* alarm, write, close */
#include <syslog.h>  /* openlog, syslog */
#include <errno.h>   /* errno, E* */
#include <dlfcn.h>  /* dlopen, dlsym, dlclose */

#include <sys/stat.h> /* stat */


#undef ASSERT_RETCODE_VARIABLE_NAME
#define ASSERT_RETCODE_VARIABLE_NAME  exit_code

#define ASSERT_VFSW_RESULT_OK(_res_, _retcode_, _func_)  \
	ASSERT_PRINTF((_res_) == VFSW_RESULT_OK, _retcode_, "%s() => %d", (_func_), (_res_))

#define EXECUTE_IN_TIME(_sec_, _msg_, _body_)  \
	g_sigalrm_msg = (_msg_);                   \
	alarm(MIN(MAX(VFS_PROPRIETARY_CAPTURE_HELPER_TIMEOUT - (time(NULL) - startup), 0), (_sec_))); \
	_body_                                     \
	alarm(0)


static const char * g_sigalrm_msg = "";

struct vfs_wrapper_api
{
	int (*dev_init)(struct vfsw_data *);
	int (*wait_for_service)(void);
	int (*set_matcher_type)(enum vfs_matcher_type);
	enum vfsw_capture_result (*capture)(struct vfsw_data *, int);
	int (*get_img_datasize)(struct vfsw_data *);
	int (*get_img_width)(struct vfsw_data *);
	int (*get_img_height)(struct vfsw_data *);
	unsigned char * (*get_img_data)(struct vfsw_data *);
	void (*free_img_data)(unsigned char *);
	void (*clean_handles)(struct vfsw_data *);
	void (*dev_exit)(struct vfsw_data *);
};

static int
load_vfs_wrapper(struct vfs_wrapper_api * const api,
		void ** const tommath_handle, void ** const wrapper_handle)
{
	const char * tommath_path = getenv("VFS_PROPRIETARY_TOMMATH_PATH");
	const char * wrapper_path = getenv("VFS_PROPRIETARY_WRAPPER_PATH");

	if ( tommath_path == NULL || tommath_path[0] == '\0' )
		tommath_path = "libtommath.so.1";
	if ( wrapper_path == NULL || wrapper_path[0] == '\0' )
		wrapper_path = "libvfsFprintWrapper.so";

	*tommath_handle = dlopen(tommath_path, RTLD_NOW | RTLD_GLOBAL);
	if ( *tommath_handle == NULL )
	{
		fprintf(stderr, "Failed to load %s: %s\n", tommath_path, dlerror());
		return EXIT_FAILURE;
	}

	*wrapper_handle = dlopen(wrapper_path, RTLD_NOW | RTLD_GLOBAL);
	if ( *wrapper_handle == NULL )
	{
		fprintf(stderr, "Failed to load %s: %s\n", wrapper_path, dlerror());
		return EXIT_FAILURE;
	}

#define LOAD_VFS_SYMBOL(_field_, _symbol_)                                      \
	do {                                                                       \
		void * symbol_address;                                                 \
		const char * symbol_error;                                             \
		dlerror();                                                              \
		symbol_address = dlsym(*wrapper_handle, #_symbol_);                     \
		symbol_error = dlerror();                                               \
		if ( symbol_error != NULL || symbol_address == NULL )                   \
		{                                                                      \
			fprintf(stderr, "Failed to resolve %s: %s\n", #_symbol_,          \
					symbol_error != NULL ? symbol_error : "symbol is null"); \
			return EXIT_FAILURE;                                                \
		}                                                                      \
		_Static_assert(sizeof(api->_field_) == sizeof(symbol_address),          \
				"POSIX function and data pointers must have equal size");       \
		memcpy(&api->_field_, &symbol_address, sizeof(api->_field_));           \
	} while (0)

	LOAD_VFS_SYMBOL(dev_init, vfs_dev_init);
	LOAD_VFS_SYMBOL(wait_for_service, vfs_wait_for_service);
	LOAD_VFS_SYMBOL(set_matcher_type, vfs_set_matcher_type);
	LOAD_VFS_SYMBOL(capture, vfs_capture);
	LOAD_VFS_SYMBOL(get_img_datasize, vfs_get_img_datasize);
	LOAD_VFS_SYMBOL(get_img_width, vfs_get_img_width);
	LOAD_VFS_SYMBOL(get_img_height, vfs_get_img_height);
	LOAD_VFS_SYMBOL(get_img_data, vfs_get_img_data);
	LOAD_VFS_SYMBOL(free_img_data, vfs_free_img_data);
	LOAD_VFS_SYMBOL(clean_handles, vfs_clean_handles);
	LOAD_VFS_SYMBOL(dev_exit, vfs_dev_exit);

#undef LOAD_VFS_SYMBOL

	return EXIT_SUCCESS;
}


/***
 * prevent libvfsFprintWrapper from spamming syslog
 */
static const char * g_syslog_ident = "";
void
openlog(const char * ident, int option, int facility)
{
	g_syslog_ident = ident;
	return;
}
void
syslog(int priority, const char *format, ...)
{
	fprintf(stderr, "syslog: %s: ", g_syslog_ident);

	va_list ap;
	va_start(ap, format);
	vfprintf(stderr, format, ap);
	va_end(ap);

	return;
}


__attribute__ ((noreturn)) static void
sigalrm_handler(int const sig)
{
	alarm(0);

	if ( g_sigalrm_msg != NULL && g_sigalrm_msg[0] != '\0' )
	{
		fprintf(stderr, "SIGALRM caught: %s\n", g_sigalrm_msg);
	}

	exit(ETIMEDOUT);
}


int
main(int const argc, char * const argv[])
{
	int exit_code = EXIT_FAILURE;
	int iretval;
	const time_t startup = time(NULL);

	struct capture_helper_api_input  ipcin  = { 0 };
	struct capture_helper_api_img_metadata imgmeta = { 0 };

	bool vfs_initialized = false;
	struct vfsw_data vfsw_data = { 0 };
	unsigned char * vfsw_img_data = NULL;
	struct vfs_wrapper_api vfs_api = { 0 };
	void * tommath_handle = NULL;
	void * wrapper_handle = NULL;

	ASSERT_PERROR( signal(SIGALRM, sigalrm_handler) != SIG_ERR ,
					errno, "Failed to setup signal handler");


	iretval = read(STDIN_FILENO, &ipcin, sizeof(ipcin));
	ASSERT_PERROR( iretval == sizeof(ipcin) , errno, "Failed to read IPC in");
	fclose(stdin);

	iretval = load_vfs_wrapper(&vfs_api, &tommath_handle, &wrapper_handle);
	ASSERT_PRINTF( iretval == EXIT_SUCCESS, EXIT_FAILURE,
			"Failed to load the proprietary capture runtime");


	/* simple check for https://github.com/rindeal/libfprint-vfs_proprietary-driver/issues/4 */
	{
		struct stat statbuf;
		iretval = stat("/tmp/vcsSemKey_ServiceReady", &statbuf);
		if ( iretval != 0 )
		{
			fprintf(stderr, "'/tmp/vcsSemKey_ServiceReady': %s. Make sure the `vcsFPService` daemon is running under the same `/tmp` namespace as this process.\n", strerror(errno));
		}
	}


	EXECUTE_IN_TIME(5, "timed out waiting for VFS service",
		iretval = vfs_api.wait_for_service();
		ASSERT_VFSW_RESULT_OK(iretval, EXIT_FAILURE, "vfs_wait_for_service");
	);
	EXECUTE_IN_TIME(5, "timed out waiting for VFS wrapper to initialize",
		iretval = vfs_api.set_matcher_type(VFS_FPRINT_MATCHER);
		ASSERT_VFSW_RESULT_OK(iretval, EXIT_FAILURE, "vfs_set_matcher_type");

		/*
		 * vfs_dev_init() can fail and block the execution forever.
		 * gdb says it locks itself up when writing to a pipe which it uses
		 * for communication with vcsFPService.
		 *
		 * The lockup can be triggered by `kill -9`ing application waiting on vfs_capture().
		 *
		 * Usually it takes about 0.4s to execute.
		 *
		 * This function also prints to stdout messages like this:
		 *
		 *     Sensor usb#vid_138a#pid_003f#... plugged.
		 *
		 */
		iretval = vfs_api.dev_init(&vfsw_data);
		ASSERT_VFSW_RESULT_OK(iretval, EXIT_FAILURE, "vfs_dev_init");
	);
	vfs_initialized = true;

	/*
	 * The working VFS495 reference keeps the initialized wrapper alive before
	 * asking it to capture.  Allow the diagnostic stack to reproduce that
	 * warm-device interval without imposing latency on normal libfprint use.
	 */
	{
		const char * const warmup_text = getenv("VFS495_CAPTURE_WARMUP_MS");
		if ( warmup_text != NULL && warmup_text[0] != '\0' )
		{
			char * end = NULL;
			errno = 0;
			unsigned long const warmup_ms = strtoul(warmup_text, &end, 10);
			ASSERT_PRINTF(
				errno == 0 && end != warmup_text && *end == '\0' && warmup_ms <= 30000,
				EXIT_FAILURE, "Invalid VFS495_CAPTURE_WARMUP_MS value");

			struct timespec delay = {
				.tv_sec = warmup_ms / 1000,
				.tv_nsec = (warmup_ms % 1000) * 1000000,
			};
			while ( nanosleep(&delay, &delay) != 0 && errno == EINTR )
				;
		}
	}


	EXECUTE_IN_TIME(VFS_PROPRIETARY_CAPTURE_HELPER_TIMEOUT, "Timed out waiting for capture",
		/* this will fail if some other instance tries the same while we're waiting for swipe */
		for (unsigned int attempt = 1; attempt <= VFS_PROPRIETARY_CAPTURE_ATTEMPTS; attempt++)
		{
			iretval = vfs_api.capture(&vfsw_data, 1);
			if ( iretval == VFSW_CAPTURE_COMPLETE )
				break;

			fprintf(stderr, "Capture attempt %u/%u returned %d\n",
					attempt, VFS_PROPRIETARY_CAPTURE_ATTEMPTS, iretval);
			if ( attempt < VFS_PROPRIETARY_CAPTURE_ATTEMPTS )
			{
				struct timespec retry_delay = { 0 };
				retry_delay.tv_nsec = 200000000;
				nanosleep(&retry_delay, NULL);
			}
		}
		ASSERT_PRINTF( iretval == VFSW_CAPTURE_COMPLETE , EXIT_FAILURE,
				"Could not capture fingerprint after %u attempts", VFS_PROPRIETARY_CAPTURE_ATTEMPTS);
	);


	EXECUTE_IN_TIME(1, "Timed out waiting for data to be passed to parent",
		struct capture_helper_api_img_ready const img_is_ready = { .status = CAPTURE_HELPER_IMG_READY_OK };
		ASSERT_PERROR(
			write(ipcin.img_ready_fd, &img_is_ready, sizeof(img_is_ready)) == sizeof(img_is_ready),
			errno, "Failed to announce img ready status"
		);
		close(ipcin.img_ready_fd);

		vfsw_img_data = vfs_api.get_img_data(&vfsw_data);
		imgmeta.img_len = vfs_api.get_img_datasize(&vfsw_data);
		imgmeta.img_w = vfs_api.get_img_width(&vfsw_data);
		imgmeta.img_h = vfs_api.get_img_height(&vfsw_data);
		ASSERT_PRINTF( vfsw_img_data != NULL && imgmeta.img_len > 0 , EXIT_FAILURE, "Empty image captured");

		ASSERT_PERROR(
			write(ipcin.img_meta_fd, &imgmeta, sizeof(imgmeta)) == sizeof(imgmeta),
			errno, "Failed to write IPC out"
		);
		close(ipcin.img_meta_fd);

		ASSERT_PERROR(
			write(ipcin.img_data_fd, vfsw_img_data, imgmeta.img_len) == imgmeta.img_len,
			errno, "Failed to write image data"
		);
		close(ipcin.img_data_fd);
	);


	exit_code = EXIT_SUCCESS;

cleanup:
	/* disarm pending alarm if any */
	alarm(0);

	if ( vfs_initialized )
	{
		EXECUTE_IN_TIME(2, "failed to cleanup vfs",
			if ( vfsw_img_data != NULL )
			{
				vfs_api.free_img_data(vfsw_img_data);
			}

			vfs_api.clean_handles(&vfsw_data);
			vfs_api.dev_exit(&vfsw_data);
		);
	}

	if ( wrapper_handle != NULL )
		dlclose(wrapper_handle);
	if ( tommath_handle != NULL )
		dlclose(tommath_handle);

	return exit_code;
}
