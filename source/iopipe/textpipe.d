/**
Copyright: Copyright Steven Schveighoffer 2011-.
License:   Boost License 1.0. (See accompanying file LICENSE_1_0.txt or copy at
           http://www.boost.org/LICENSE_1_0.txt)
Authors:   Steven Schveighoffer
 */
module iopipe.textpipe;
import iopipe.bufpipe;
import iopipe.traits;
import std.range: ElementType;
import std.traits: Unqual;

enum UTFType
{
    Unknown,
    UTF8,
    UTF16LE,
    UTF16BE,
    UTF32LE,
    UTF32BE
}

template CodeUnit(UTFType u)
{
    static if(u == UTFType.Unknown || u == UTFType.UTF8)
        alias CodeUnit = char;
    else static if(u == UTFType.UTF16LE || u == UTFType.UTF16BE)
        alias CodeUnit = wchar;
    else static if(u == UTFType.UTF32LE || u == UTFType.UTF32BE)
        alias CodeUnit = dchar;
    else
        static assert(0);
}

UTFType detectBOM(R)(R r)
{
    if(r.length >= 2)
    {
        if(r[0] == 0xFE && r[1] == 0xFF)
            return UTFType.UTF16BE;
        if(r[0] == 0xFF && r[1] == 0xFE)
        {
            if(r.length >= 4 && r[2] == 0 && r[3] == 0)
            {
                // most likely UTF32
                return UTFType.UTF32LE;
            }
            return UTFType.UTF16LE;
        }

        if(r.length >= 3 && r[0] == 0xEF && r[1] == 0xBB && r[2] == 0xBF)
            return UTFType.UTF8;
        if(r.length >= 4 && r[0] == 0 && r[1] == 0 && r[2] == 0xFE && r[3] == 0xFF)
            return UTFType.UTF32BE;
    }
    return UTFType.Unknown;
}

// ensure that part of a code point isn't at the end of the window
auto ensureDecodeable(Chain)(Chain c)
{
    import std.traits: Unqual;
    alias CodeUnitType = Unqual!(typeof(c.window[0]));
    static if(is(CodeUnitType == dchar))
    {
        // always decodeable
        return c;
    }
    else
    {
        static struct DecodeableWindow
        {
            Chain chain;
            ubyte partial;
            auto window() { return chain.window[0 .. $-partial]; }
            void release(size_t elements) { chain.release(elements); }
            private void determinePartial()
            {
                static if(is(CodeUnitType == char))
                {
                    auto w = chain.window;
                    // ends on a multi-char sequence. Ensure it's valid.
                    // find the encoding
ee_outer:
                    foreach(ubyte i; 1 .. 4)
                    {
                        import core.bitop : bsr;
                        import std.stdio;
                        if(w.length < i)
                        {
                            // either no data, or invalid sequence.
                            if(i > 1)
                            {
                                // TODO: throw some error?
                                stderr.writeln("oops!");
                            }
                            partial = 0;
                            break ee_outer;
                        }
                        immutable highestBit = bsr(~w[$ - i] & 0x0ff);
                        switch(highestBit)
                        {
                        case 7:
                            // ascii character
                            if(i > 1)
                            {
                                stderr.writeln("oops!");
                            }
                            partial = 0;
                            break ee_outer;
                        case 6:
                            // need to continue looking
                            break;
                        case 3: .. case 5:
                            // 5 -> 2 byte sequence
                            // 4 -> 3 byte sequence
                            // 3 -> 4 byte sequence
                            if(i + highestBit == 7)
                                // complete sequence, let it pass.
                                partial = 0;
                            else
                                // skip these, the whole sequence isn't there yet.
                                partial = i;
                            break ee_outer;
                        default:
                            // invalid sequence, let it fail
                            // TODO: throw some error?
                            stderr.writeln("oops!");
                            partial = 0;
                            break ee_outer;
                        }
                    }
                }
                else // wchar
                {
                    // if the last character is in 0xD800 - 0xDBFF, then it is
                    // the first wchar of a surrogate pair. This means we must
                    // leave it off the end.
                    partial = (chain.window[$-1] & 0xFC00) == 0xD800 ? 1 : 0;
                }
            }
            size_t extend(size_t elements)
            {
                auto origWindowSize = window.length;
                chain.extend(elements > partial ? elements - partial : elements);
                determinePartial();
                // TODO: may need to loop if we are getting one char at a time.
                return window.length - origWindowSize;
            }

            mixin implementValve!chain;
        }

        auto r = DecodeableWindow(c);
        r.determinePartial();
        return r;
    }
}

// call this after detecting the byte order/width
auto asText(UTFType b, Chain)(Chain c)
{
    static if(b == UTFType.UTF8 || b == UTFType.Unknown)
        return c.arrayCastPipe!char;
    else static if(b == UTFType.UTF16LE || b == UTFType.UTF32LE)
    {
        return c.arrayCastPipe!(CodeUnit!b).byteSwapper!true;
    }
    else static if(b == UTFType.UTF16BE || b == UTFType.UTF32BE)
    {
        return c.arrayCastPipe!(CodeUnit!b).byteSwapper!false;
    }
    else
        static assert(0);
}

private struct ByLinePipe(Chain)
{
    alias CodeUnitType = Unqual!(typeof(Chain.init.window[0]));
    private
    {
        Chain chain;
        size_t checked;
        size_t _lines;
        CodeUnitType[dchar.sizeof / CodeUnitType.sizeof] delimElems;
        static if(is(CodeUnitType == dchar))
        {
            enum validDelimElems = 1;
            enum skippableElems = 1;
        }
        else
        {
            // number of elements in delimElems that are valid
            ubyte validDelimElems;
            // number of elements that can be skipped if the sequence fails
            // to match. This basically is the number of elements that are
            // not the first element (except the first element of course).
            ubyte skippableElems;
        }
    }

    auto window() { return chain.window[0 .. checked]; }
    void release(size_t elements)
    {
        checked -= elements;
        chain.release(elements);
    }

    size_t extend(size_t elements = 0)
    {
        auto prevChecked = checked;
        if(validDelimElems == 1)
        {
            // simple scan per element
byline_outer_1:
            do
            {
                auto w = chain.window;
                while(checked < w.length)
                {
                    if(w[checked] == delimElems[0])
                    {
                        // found it.
                        ++checked;
                        break byline_outer_1;
                    }
                    ++checked;
                }
            } while(chain.extend(elements) != 0);
        }
        else // shouldn't be compiled in the case of dchar
        {
            // need to check multiple elements
byline_outer_2:
            while(true)
            {
                auto w = chain.window;
                while(checked + validDelimElems <= w.length)
                {
                    size_t i = 0;
                    auto ptr = delimElems.ptr;
                    while(i < validDelimElems)
                    {
                        if(w[checked + i] != *ptr++)
                        {
                            checked += i < skippableElems ? i + 1 : skippableElems;
                            continue byline_outer_2;
                        }
                        ++i;
                    }
                    // found it
                    checked += validDelimElems;
                    break byline_outer_2;
                }

                // need to read more data
                if(chain.extend(elements) == 0)
                {
                    checked = chain.window.length;
                    break;
                }
            }
        }

        if(checked != prevChecked)
            ++_lines;
        return checked - prevChecked;
    }

    size_t lines() { return _lines; }
}

auto byLine(Chain)(Chain c, dchar delim = '\n')
   if(isIopipe!Chain &&
      is(Unqual!(ElementType!(windowType!Chain)) == dchar))
{
    import std.traits: Unqual;
    auto r = ByLinePipe!Chain(c);
    // set up the delimeter
    static if(is(r.CodeUnitType == dchar))
    {
        r.delimElems[0] = delim;
    }
    else
    {
        import std.utf: encode;
        r.validDelimElems = cast(ubyte)encode(r.delimElems, delim);
        r.skippableElems = 1; // need to be able to skip at least one element
        foreach(x; r.delimElems[1 .. r.validDelimElems])
        {
            if(x == r.delimElems[0])
                break;
            ++r.skippableElems;
        }
    }
    return r;
}

static struct TextOutput(Chain)
{
    Chain chain;
    alias CT = typeof(Chain.init.window[0]);

    // TODO: allow putting of strings

    void put(A)(A c)
    {
        import std.utf;
        static if(A.sizeof == CT.sizeof)
        {
            // output the data directly to the output stream
            if(chain.ensureElems(1) == 0)
                assert(0);
            chain.window[0] = c;
            chain.release(1);
        }
        else
        {
            static if(is(CT == char))
            {
                static if(is(A : const(wchar)))
                {
                    // A is a wchar.  Make sure it's not a surrogate pair
                    // (that it's a valid dchar)
                    if(!isValidDchar(c))
                        assert(0);
                }
                // convert the character to utf8
                if(c <= 0x7f)
                {
                    if(chain.ensureElems(1) == 0)
                        assert(0);
                    chain.window[0] = cast(char)c;
                    chain.release(1);
                }
                else
                {
                    char[4] buf = void;
                    auto idx = 3;
                    auto mask = 0x3f;
                    dchar c2 = c;
                    while(c2 > mask)
                    {
                        buf[idx--] = 0x80 | (c2 & 0x3f);
                        c2 >>= 6;
                        mask >>= 1;
                    }
                    buf[idx] = (c2 | (~mask << 1)) & 0xff;
                    auto x = buf.ptr[idx..buf.length]; 
                    if(chain.ensureElems(x.length) < x.length)
                        assert(0);
                    chain.window[0 .. x.length] = x;
                    chain.release(x.length);
                }
            }
            else static if(is(CT == wchar))
            {
                static if(is(A : const(char)))
                {
                    // this is a utf-8 character, only works if it's an
                    // ascii character
                    if(c > 0x7f)
                        throw new Exception("invalid character output");
                }
                // convert the character to utf16
                assert(isValidDchar(c));
                if(c < 0xFFFF)
                {
                    if(chain.ensureElems(1) == 0)
                        assert(0);
                    chain.window[0] = cast(wchar)c;
                    chain.release(1);
                }
                else
                {
                    if(chain.ensureElems(2) < 2)
                        assert(0);
                    wchar[2] buf = void;
                    dchar dc = c - 0x10000;
                    buf[0] = cast(wchar)(((dc >> 10) & 0x3FF) + 0xD800);
                    buf[1] = cast(wchar)((dc & 0x3FF) + 0xDC00);
                    chain.window[0..2] = buf;
                    chain.release(2);
                }
            }
            else static if(is(CT == dchar))
            {
                static if(is(A : const(char)))
                {
                    // this is a utf-8 character, only works if it's an
                    // ascii character
                    if(c > 0x7f)
                        throw new Exception("invalid character output");
                }
                else static if(is(A : const(wchar)))
                {
                    // A is a wchar.  Make sure it's not a surrogate pair
                    // (that it's a valid dchar)
                    if(!isValidDchar(c))
                        throw new Exception("invalid character output");
                }
                // converting to utf32, just write directly
                if(chain.ensureElems(1) == 0)
                    assert(0);
                chain.window[0] = c;
                chain.release(1);
            }
            else
                static assert(0, "invalid types used for output stream, " ~ CT.stringof ~ ", " ~ C.stringof);
        }
    }
}
auto textOutput(Chain)(Chain c)
{
    // create an output range of dchar/code units around c. We assume releasing and
    // extending c will properly output the data.

    return TextOutput!Chain(c);
}

auto encodeText(UTFType enc, Chain)(Chain c)
{
    static assert(is(typeof(c.window[0]) == CodeUnit!enc));

    static if(enc == UTFType.UTF8)
    {
        return c.arrayCastPipe!ubyte;
    }
    else static if(enc == UTFType.UTF16LE || enc == UTFType.UTF32LE)
    {
        return c.byteSwapper!(true).arrayCastPipe!ubyte;
    }
    else static if(enc == UTFType.UTF16BE || enc == UTFType.UTF32BE)
    {
        return c.byteSwapper!(false).arrayCastPipe!ubyte;
    }
    else
        assert(0);
}
