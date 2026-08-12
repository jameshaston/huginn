package main

import "core:math"
import "core:mem"

DEFAULT_DISPLAY_DECIMALS :: 2

/*
Round a floating-point value to a fixed number of decimal places.

Inputs:
- value: The value to round
- decimals: Number of decimal places to keep (default DEFAULT_DISPLAY_DECIMALS)

Returns:
- rounded: value rounded to decimals places

Example:
	round_to(15.473270416259766)
	round_to(15.473270416259766, 3)

Output:
	15.47
	15.473
*/
round_to :: proc(value: f64, decimals: int = DEFAULT_DISPLAY_DECIMALS) -> f64 {
	scale := math.pow(10.0, f64(decimals))
	return math.round(value * scale) / scale
}

/*
Convert a byte count to kibibytes (KiB) as f64.

Inputs:
- bytes: Byte count (non-negative)

Returns:
- value: bytes / 1024 as f64

Example:
	bytes_to_kib(1048576)

Output:
	1024.0
*/
bytes_to_kib :: proc(bytes: i64) -> f64 {
	return f64(bytes) / f64(mem.Kilobyte)
}

/*
Convert a byte count to mebibytes (MiB) as f64.

Inputs:
- bytes: Byte count (non-negative)

Returns:
- value: bytes / 1024^2 as f64

Example:
	bytes_to_mib(1073741824)

Output:
	1024.0
*/
bytes_to_mib :: proc(bytes: i64) -> f64 {
	return f64(bytes) / f64(mem.Megabyte)
}

/*
Convert a byte count to gibibytes (GiB) as f64.

Inputs:
- bytes: Byte count (non-negative)

Returns:
- value: bytes / 1024^3 as f64

Example:
	bytes_to_gib(34359738368)

Output:
	32.0
*/
bytes_to_gib :: proc(bytes: i64) -> f64 {
	return f64(bytes) / f64(mem.Gigabyte)
}

/*
Convert a byte count to tebibytes (TiB) as f64.

Inputs:
- bytes: Byte count (non-negative)

Returns:
- value: bytes / 1024^4 as f64

Example:
	bytes_to_tib(1099511627776)

Output:
	1.0
*/
bytes_to_tib :: proc(bytes: i64) -> f64 {
	return f64(bytes) / f64(mem.Terabyte)
}
