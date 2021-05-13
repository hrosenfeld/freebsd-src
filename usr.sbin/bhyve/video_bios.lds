SECTIONS
{
  .text 0x0000 : { *(.bios) }
  _start = 0;
}
