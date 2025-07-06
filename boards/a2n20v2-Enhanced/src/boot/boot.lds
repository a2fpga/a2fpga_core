SECTIONS {
	. = 0x04400000;
	.memory : {
		*(.init);
		*(.text);
		*(*);
		. = ALIGN(4);
		_end = .; PROVIDE (end = .);
	}
}

