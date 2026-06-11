/* Linker script: controls where each part of the kernel lands in memory.
   We place the kernel in the higher half and emit page-aligned sections with
   their own program headers so the bootloader can map them with correct
   permissions and the VMM can re-map them per section (W^X). */

/* Produce a 64-bit x86 ELF. */
OUTPUT_FORMAT(elf64-x86-64)

/* The kernel's entry symbol (defined in main.zig as `export fn _start`). */
ENTRY(_start)

/* Program headers (segments). Each PT_LOAD becomes a loadable segment; giving
   each section its own segment lets us control its mapping/permissions. */
PHDRS
{
    limine_requests PT_LOAD; /* the Limine request structs */
    text PT_LOAD;            /* executable code */
    rodata PT_LOAD;          /* read-only constants */
    data PT_LOAD;            /* read-write data + .bss */
}

SECTIONS
{
    /* Higher half: top 2 GiB of the 64-bit address space. The Limine spec
       mandates this region; 0xffffffff80000000 is its base. */
    . = 0xffffffff80000000;
    __kernel_start = .; /* VMM uses this as the image start */

    /* The Limine requests, kept (KEEP) so the linker doesn't garbage-collect
       them, and given their own segment. */
    .limine_requests : {
        KEEP(*(.limine_requests_start)) /* start marker */
        KEEP(*(.limine_requests))       /* the request structs */
        KEEP(*(.limine_requests_end))   /* end marker */
    } :limine_requests

    /* Page-align before .text so it can be mapped with its own permissions. */
    . = ALIGN(CONSTANT(MAXPAGESIZE));
    __text_start = .; /* VMM maps [__text_start, __text_end) as execute + read-only */

    .text : {
        *(.text .text.*) /* all code */
    } :text

    /* Page-align before .rodata. */
    . = ALIGN(CONSTANT(MAXPAGESIZE));
    __text_end = .;     /* end of code */
    __rodata_start = .; /* VMM maps [__rodata_start, __rodata_end) as read-only + NX */

    .rodata : {
        *(.rodata .rodata.*) /* constants, string literals, etc. */
    } :rodata

    /* Page-align before .data. */
    . = ALIGN(CONSTANT(MAXPAGESIZE));
    __rodata_end = .;  /* end of rodata */
    __data_start = .;  /* VMM maps [__data_start, __kernel_end) as read-write + NX */

    .data : {
        *(.data .data.*) /* initialized writable data */
    } :data

    /* NOTE: .bss needs to be the last thing mapped to :data, otherwise lots of
       unnecessary zeros will be written to the binary.
       If you need, for example, .init_array and .fini_array, those should be
       placed above this. */
    .bss : {
        *(.bss .bss.*) /* zero-initialized data (GDT/IDT/TSS/stacks live here) */
        *(COMMON)      /* common symbols */
    } :data

    /* Page-aligned end of the kernel image, so the VMM can map [start, end). */
    . = ALIGN(CONSTANT(MAXPAGESIZE));
    __kernel_end = .;

    /* Drop sections that can cause issues on some hosts and that we don't use. */
    /DISCARD/ : {
        *(.eh_frame*)       /* unwind info */
        *(.note .note.*)    /* build notes */
    }
}
