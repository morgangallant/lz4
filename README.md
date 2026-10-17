# lz4
Learning how LZ4 works by writing it in Zig

- Data as series of sequences
- Each sequence begins with one byte token
  - First 4-bit field: number of literal bytes that are to be copied
  - Second 4-bit field: number of bytes to copy from already decoded output
    - (0 means maximum, e.g. 4 bytes)
- Value of 15 in either field means length is larger, and there is extra byte
of data that is added to length. If that extra byte is 255, then there is another extra byte, and so on.

## Resources

- https://en.wikipedia.org/wiki/LZ4_(compression_algorithm)
- https://github.com/lz4/lz4/blob/dev/doc/lz4_Frame_format.md
- https://github.com/lz4/lz4/blob/dev/doc/lz4_Block_format.md
- https://fastcompression.blogspot.com/2011/05/lz4-explained.html
- https://ticki.github.io/blog/how-lz4-works/
