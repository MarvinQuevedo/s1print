using System.Buffers.Binary;
using System.Text;

namespace S1Print.Engine;

public sealed record IppAttribute(byte Tag, string Name, byte[] Value);
public sealed record IppRequest(ushort Operation, int Id, IReadOnlyList<IppAttribute> Attributes, byte[] Document)
{
    public string Text(string name, string fallback = "") => Attributes.FirstOrDefault(a => a.Name == name) is { } a ? Encoding.UTF8.GetString(a.Value) : fallback;
    public int Number(string name, int fallback = 0) => Attributes.FirstOrDefault(a => a.Name == name) is { Value.Length: 4 } a ? BinaryPrimitives.ReadInt32BigEndian(a.Value) : fallback;
    public bool Boolean(string name, bool fallback = false) => Attributes.FirstOrDefault(a => a.Name == name) is { Value.Length: 1 } a ? a.Value[0] != 0 : fallback;
}

public static class IppCodec
{
    public static IppRequest Parse(byte[] bytes)
    {
        if (bytes.Length < 9) throw new InvalidDataException("Truncated IPP request");
        if (bytes[0] is not (1 or 2)) throw new InvalidDataException("Unsupported IPP version");
        int pos = 8, count = 0;
        var attributes = new List<IppAttribute>();
        string name = "", member = "";
        int depth = 0;
        while (pos < bytes.Length)
        {
            byte tag = bytes[pos++];
            if (tag == 3)
            {
                if (depth != 0) throw new InvalidDataException("Unclosed collection");
                return new(BinaryPrimitives.ReadUInt16BigEndian(bytes.AsSpan(2)), BinaryPrimitives.ReadInt32BigEndian(bytes.AsSpan(4)), attributes, bytes[pos..]);
            }
            if (tag <= 0x0f) { name = ""; continue; }
            if (++count > 8192) throw new InvalidDataException("Too many IPP attributes");
            byte[] ReadField()
            {
                if (pos + 2 > bytes.Length) throw new InvalidDataException("Truncated IPP field length");
                int length = BinaryPrimitives.ReadUInt16BigEndian(bytes.AsSpan(pos)); pos += 2;
                if (pos + length > bytes.Length) throw new InvalidDataException("Truncated IPP field");
                byte[] result = bytes.AsSpan(pos, length).ToArray(); pos += length; return result;
            }
            var fieldName = ReadField(); var value = ReadField();
            if (fieldName.Length > 0) name = Encoding.UTF8.GetString(fieldName);
            // Only top-level job attributes are interpreted. Nested media collections remain in raw attributes.
            if (depth == 0) attributes.Add(new(tag, name, value));
            else if (tag == 0x4a) member = Encoding.UTF8.GetString(value);
            else if (tag is not (0x34 or 0x37)) attributes.Add(new(tag, member, value));
            if (tag == 0x34) depth++;
            if (tag == 0x37) depth--;
            if (depth < 0 || depth > 8) throw new InvalidDataException("Invalid IPP collection depth");
        }
        throw new InvalidDataException("Missing end-of-attributes tag");
    }
}

public sealed class IppWriter
{
    private readonly MemoryStream stream = new();
    private byte? pendingGroup;
    private int depth;
    private bool keep = true;
    public HashSet<string>? Filter { get; set; }
    public IppWriter(ushort status, int requestId)
    {
        stream.Write([2, 0]); Word(status); Int(requestId);
        Group(1); Text(0x47, "attributes-charset", "utf-8"); Text(0x48, "attributes-natural-language", "en");
    }
    private void Word(int n) { Span<byte> b = stackalloc byte[2]; BinaryPrimitives.WriteUInt16BigEndian(b, checked((ushort)n)); stream.Write(b); }
    private void Int(int n) { Span<byte> b = stackalloc byte[4]; BinaryPrimitives.WriteInt32BigEndian(b, n); stream.Write(b); }
    public void Group(byte tag) { pendingGroup = tag; keep = true; }
    public void Raw(byte tag, string name, byte[] value)
    {
        if (depth == 0 && name != "") keep = Filter is null || Filter.Contains(name);
        if (keep)
        {
            if (pendingGroup is byte group) { stream.WriteByte(group); pendingGroup = null; }
            stream.WriteByte(tag); byte[] key = Encoding.UTF8.GetBytes(name); Word(key.Length); stream.Write(key); Word(value.Length); stream.Write(value);
        }
        if (tag == 0x34) depth++; else if (tag == 0x37) depth--;
    }
    public void Text(byte tag, string name, string value) => Raw(tag, name, Encoding.UTF8.GetBytes(value));
    public void Texts(byte tag, string name, params string[] values) { for (int i = 0; i < values.Length; i++) Text(tag, i == 0 ? name : "", values[i]); }
    public void Number(byte tag, string name, int value) { byte[] b = new byte[4]; BinaryPrimitives.WriteInt32BigEndian(b, value); Raw(tag, name, b); }
    public void Numbers(byte tag, string name, params int[] values) { for (int i = 0; i < values.Length; i++) Number(tag, i == 0 ? name : "", values[i]); }
    public void Boolean(string name, bool value) => Raw(0x22, name, [(byte)(value ? 1 : 0)]);
    public void Range(string name, int low, int high) { byte[] b = new byte[8]; BinaryPrimitives.WriteInt32BigEndian(b, low); BinaryPrimitives.WriteInt32BigEndian(b.AsSpan(4), high); Raw(0x33, name, b); }
    public void Resolution(string name, int dpi) { byte[] b = new byte[9]; BinaryPrimitives.WriteInt32BigEndian(b, dpi); BinaryPrimitives.WriteInt32BigEndian(b.AsSpan(4), dpi); b[8] = 3; Raw(0x32, name, b); }
    public void Begin(string name) => Raw(0x34, name, []);
    public void Member(string name) => Text(0x4a, "", name);
    public void End() => Raw(0x37, "", []);
    public byte[] Finish() { stream.WriteByte(3); return stream.ToArray(); }
}
