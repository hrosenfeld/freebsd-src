/*
 * Copyright 2006-2007 Advanced Micro Devices, Inc.
 * Copyright 2021 Beckhoff Automation GmbH & Co. KG
 *
 * Permission is hereby granted, free of charge, to any person obtaining a
 * copy of this software and associated documentation files (the "Software"),
 * to deal in the Software without restriction, including without limitation
 * the rights to use, copy, modify, merge, publish, distribute, sublicense,
 * and/or sell copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL
 * THE COPYRIGHT HOLDER(S) OR AUTHOR(S) BE LIABLE FOR ANY CLAIM, DAMAGES OR
 * OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,
 * ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
 * OTHER DEALINGS IN THE SOFTWARE.
 */

/*
 * This file is a modified copy of <https://github.com/torvalds/linux/blob/229f7b1d6344ea35fff0b113e4d91128921f8937/drivers/gpu/drm/amd/include/atombios.h>
 */

/****************************************************************************/
/*Portion I: Definitions  shared between VBIOS and Driver                   */
/****************************************************************************/

#pragma once

typedef unsigned long ULONG;
typedef unsigned char UCHAR;
typedef unsigned short USHORT;

//
// AMD ACPI Table
//
#pragma pack(1)

typedef struct {
  ULONG Signature;
  ULONG TableLength;      //Length
  UCHAR Revision;
  UCHAR Checksum;
  UCHAR OemId[6];
  UCHAR OemTableId[8];    //UINT64  OemTableId;
  ULONG OemRevision;
  ULONG CreatorId;
  ULONG CreatorRevision;
} AMD_ACPI_DESCRIPTION_HEADER;

typedef struct {
  AMD_ACPI_DESCRIPTION_HEADER SHeader;
  UCHAR TableUUID[16];    //0x24
  ULONG VBIOSImageOffset; //0x34. Offset to the first GOP_VBIOS_CONTENT block from the beginning of the stucture.
  ULONG Lib1ImageOffset;  //0x38. Offset to the first GOP_LIB1_CONTENT block from the beginning of the stucture.
  ULONG Reserved[4];      //0x3C
}UEFI_ACPI_VFCT;

typedef struct {
  ULONG  PCIBus;          //0x4C
  ULONG  PCIDevice;       //0x50
  ULONG  PCIFunction;     //0x54
  USHORT VendorID;        //0x58
  USHORT DeviceID;        //0x5A
  USHORT SSVID;           //0x5C
  USHORT SSID;            //0x5E
  ULONG  Revision;        //0x60
  ULONG  ImageLength;     //0x64
}VFCT_IMAGE_HEADER;

typedef struct {
  VFCT_IMAGE_HEADER   VbiosHeader;
  UCHAR   VbiosContent[1];
}GOP_VBIOS_CONTENT;

#pragma pack()
