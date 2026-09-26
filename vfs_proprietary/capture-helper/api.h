/*******************************************************************************
 * Copyright 2018  Jan Chren (rindeal)
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

#ifndef VFS_PROPRIETARY_CAPTURE_HELPER_H_
#define VFS_PROPRIETARY_CAPTURE_HELPER_H_

#include <stdint.h>


#ifndef VFS_PROPRIETARY_CAPTURE_HELPER_TIMEOUT
#  define VFS_PROPRIETARY_CAPTURE_HELPER_TIMEOUT  30
#endif

#ifndef VFS_PROPRIETARY_CAPTURE_ATTEMPTS
#  define VFS_PROPRIETARY_CAPTURE_ATTEMPTS  5
#endif


struct __attribute__ ((__packed__)) capture_helper_api_input
{
	int img_ready_fd;
	int img_meta_fd;
	int img_data_fd;
};


#define CAPTURE_HELPER_IMG_READY_OK UINT64_C(0xAAAAAAAAAAAAAAAA)

struct __attribute__ ((__packed__)) capture_helper_api_img_ready
{
	uint64_t status;
};


struct __attribute__ ((__packed__)) capture_helper_api_img_metadata
{
	int img_len;
	int img_w;
	int img_h;
};


#endif // VFS_PROPRIETARY_CAPTURE_HELPER_H_
