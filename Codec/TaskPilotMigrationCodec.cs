using System;
using System.Collections;
using System.Collections.Generic;
using System.Collections.Specialized;
using System.Globalization;
using System.Text;

namespace TaskPilot.Migration
{
    // A JSON number is source text, never a double or a culture-dependent value.
    public sealed class JsonNumber
    {
        private readonly string lexeme;
        public string Lexeme { get { return lexeme; } }
        public JsonNumber(string value)
        {
            if (!Codec.IsNumberToken(value)) throw new FormatException("Invalid JSON number literal.");
            lexeme = value;
        }
        public override string ToString() { return lexeme; }
    }

    public static class Codec
    {
        private const int MaximumDepth = 64;

        public static object ParseJson(string text)
        {
            if (text == null) throw new ArgumentNullException("text");
            return new JsonParser(text).Parse();
        }

        public static string[][] ParseCsv(string text)
        {
            if (text == null) throw new ArgumentNullException("text");
            List<string[]> rows = new List<string[]>();
            int position = text.Length > 0 && text[0] == '\uFEFF' ? 1 : 0;
            while (position < text.Length)
            {
                List<string> fields = new List<string>();
                bool endRecord = false;
                while (!endRecord)
                {
                    StringBuilder field = new StringBuilder();
                    if (position < text.Length && text[position] == '"')
                    {
                        position++;
                        bool closed = false;
                        while (position < text.Length)
                        {
                            char character = text[position++];
                            if (character == '"')
                            {
                                if (position < text.Length && text[position] == '"')
                                {
                                    field.Append('"');
                                    position++;
                                }
                                else { closed = true; break; }
                            }
                            else field.Append(character);
                        }
                        if (!closed) throw CsvError(position, "Unclosed quoted field");
                        if (position < text.Length && text[position] != ',' && text[position] != '\r' && text[position] != '\n')
                            throw CsvError(position, "Unexpected character after closing quote");
                    }
                    else
                    {
                        while (position < text.Length && text[position] != ',' && text[position] != '\r' && text[position] != '\n')
                        {
                            char character = text[position++];
                            if (character == '"') throw CsvError(position - 1, "Quote inside an unquoted field");
                            field.Append(character);
                        }
                    }
                    fields.Add(field.ToString());
                    if (position >= text.Length) endRecord = true;
                    else if (text[position] == ',') position++;
                    else
                    {
                        if (text[position] == '\r' && position + 1 < text.Length && text[position + 1] == '\n') position += 2;
                        else position++;
                        endRecord = true;
                    }
                }
                rows.Add(fields.ToArray());
            }
            return rows.ToArray();
        }

        public static string ToJson(object value)
        {
            StringBuilder output = new StringBuilder();
            WriteJson(output, value, 0);
            return output.ToString();
        }

        internal static bool IsNumberToken(string text)
        {
            if (String.IsNullOrEmpty(text)) return false;
            int position = 0;
            if (text[position] == '-') { position++; if (position == text.Length) return false; }
            if (text[position] == '0')
            {
                position++;
                if (position < text.Length && IsDigit(text[position])) return false;
            }
            else
            {
                if (text[position] < '1' || text[position] > '9') return false;
                while (position < text.Length && IsDigit(text[position])) position++;
            }
            if (position < text.Length && text[position] == '.')
            {
                position++;
                int first = position;
                while (position < text.Length && IsDigit(text[position])) position++;
                if (position == first) return false;
            }
            if (position < text.Length && (text[position] == 'e' || text[position] == 'E'))
            {
                position++;
                if (position < text.Length && (text[position] == '+' || text[position] == '-')) position++;
                int first = position;
                while (position < text.Length && IsDigit(text[position])) position++;
                if (position == first) return false;
            }
            return position == text.Length;
        }

        private static bool IsDigit(char value) { return value >= '0' && value <= '9'; }
        private static FormatException CsvError(int position, string message)
        {
            return new FormatException(message + " at CSV character " + position.ToString(CultureInfo.InvariantCulture) + ".");
        }

        private static void WriteJson(StringBuilder output, object value, int depth)
        {
            if (value == null) { output.Append("null"); return; }
            string text = value as string;
            if (text != null) { WriteString(output, text); return; }
            JsonNumber number = value as JsonNumber;
            if (number != null) { output.Append(number.Lexeme); return; }
            if (value is bool) { output.Append((bool)value ? "true" : "false"); return; }
            Type type = value.GetType();
            if (type == typeof(byte) || type == typeof(sbyte) || type == typeof(short) || type == typeof(ushort) ||
                type == typeof(int) || type == typeof(uint) || type == typeof(long) || type == typeof(ulong) || type == typeof(decimal))
            {
                output.Append(Convert.ToString(value, CultureInfo.InvariantCulture));
                return;
            }
            IDictionary dictionary = value as IDictionary;
            if (dictionary != null)
            {
                if (depth >= MaximumDepth) throw new FormatException("JSON nesting exceeds 64 containers.");
                output.Append('{');
                bool first = true;
                OrderedDictionary keys = new OrderedDictionary(StringComparer.Ordinal);
                foreach (DictionaryEntry entry in dictionary)
                {
                    string key = entry.Key as string;
                    if (key == null) throw new ArgumentException("JSON object keys must be strings.");
                    if (keys.Contains(key)) throw new ArgumentException("Duplicate JSON object key.");
                    keys.Add(key, null);
                    if (!first) output.Append(',');
                    first = false;
                    WriteString(output, key);
                    output.Append(':');
                    WriteJson(output, entry.Value, depth + 1);
                }
                output.Append('}');
                return;
            }
            IList list = value as IList;
            if (list != null)
            {
                if (depth >= MaximumDepth) throw new FormatException("JSON nesting exceeds 64 containers.");
                output.Append('[');
                for (int index = 0; index < list.Count; index++)
                {
                    if (index > 0) output.Append(',');
                    WriteJson(output, list[index], depth + 1);
                }
                output.Append(']');
                return;
            }
            throw new ArgumentException("Unsupported JSON value type: " + type.FullName + ". Floating-point and arbitrary objects are not serialized.");
        }

        private static void WriteString(StringBuilder output, string value)
        {
            output.Append('"');
            for (int index = 0; index < value.Length; index++)
            {
                char character = value[index];
                switch (character)
                {
                    case '"': output.Append("\\\""); break;
                    case '\\': output.Append("\\\\"); break;
                    case '\b': output.Append("\\b"); break;
                    case '\f': output.Append("\\f"); break;
                    case '\n': output.Append("\\n"); break;
                    case '\r': output.Append("\\r"); break;
                    case '\t': output.Append("\\t"); break;
                    default:
                        if (character < 0x20) AppendUnicodeEscape(output, character);
                        else if (Char.IsHighSurrogate(character))
                        {
                            if (index + 1 >= value.Length || !Char.IsLowSurrogate(value[index + 1])) throw new ArgumentException("Unpaired high surrogate in JSON string.");
                            AppendUnicodeEscape(output, character);
                            AppendUnicodeEscape(output, value[++index]);
                        }
                        else if (Char.IsLowSurrogate(character)) throw new ArgumentException("Unpaired low surrogate in JSON string.");
                        else output.Append(character);
                        break;
                }
            }
            output.Append('"');
        }
        private static void AppendUnicodeEscape(StringBuilder output, char character)
        {
            output.Append("\\u");
            output.Append(((int)character).ToString("X4", CultureInfo.InvariantCulture));
        }

        private sealed class JsonParser
        {
            private readonly string text;
            private int position;
            public JsonParser(string source)
            {
                text = source;
                position = text.Length > 0 && text[0] == '\uFEFF' ? 1 : 0;
            }
            public object Parse()
            {
                SkipWhite();
                object result = ReadValue(0);
                SkipWhite();
                if (position != text.Length) throw Error("Trailing content after the JSON value");
                return result;
            }
            private object ReadValue(int depth)
            {
                SkipWhite();
                if (position >= text.Length) throw Error("Expected JSON value");
                char character = text[position];
                if (character == '{') return ReadObject(depth + 1);
                if (character == '[') return ReadArray(depth + 1);
                if (character == '"') return ReadString();
                if (character == 't') { ReadLiteral("true"); return true; }
                if (character == 'f') { ReadLiteral("false"); return false; }
                if (character == 'n') { ReadLiteral("null"); return null; }
                if (character == '-' || IsDigit(character)) return ReadNumber();
                throw Error("Invalid JSON value");
            }
            private OrderedDictionary ReadObject(int depth)
            {
                if (depth > MaximumDepth) throw Error("JSON nesting exceeds 64 containers");
                position++;
                OrderedDictionary result = new OrderedDictionary(StringComparer.Ordinal);
                SkipWhite();
                if (Take('}')) return result;
                while (true)
                {
                    SkipWhite();
                    if (position >= text.Length || text[position] != '"') throw Error("Expected quoted object key");
                    string key = ReadString();
                    if (result.Contains(key)) throw Error("Duplicate decoded JSON key: " + key);
                    SkipWhite();
                    if (!Take(':')) throw Error("Expected ':' after object key");
                    object value = ReadValue(depth);
                    result.Add(key, value);
                    SkipWhite();
                    if (Take('}')) return result;
                    if (!Take(',')) throw Error("Expected ',' or '}' after object value");
                    SkipWhite();
                    if (position < text.Length && text[position] == '}') throw Error("Trailing comma in JSON object");
                }
            }
            private object[] ReadArray(int depth)
            {
                if (depth > MaximumDepth) throw Error("JSON nesting exceeds 64 containers");
                position++;
                List<object> result = new List<object>();
                SkipWhite();
                if (Take(']')) return result.ToArray();
                while (true)
                {
                    result.Add(ReadValue(depth));
                    SkipWhite();
                    if (Take(']')) return result.ToArray();
                    if (!Take(',')) throw Error("Expected ',' or ']' after array value");
                    SkipWhite();
                    if (position < text.Length && text[position] == ']') throw Error("Trailing comma in JSON array");
                }
            }
            private string ReadString()
            {
                if (!Take('"')) throw Error("Expected JSON string");
                StringBuilder output = new StringBuilder();
                while (position < text.Length)
                {
                    char character = text[position++];
                    if (character == '"') return output.ToString();
                    if (character < 0x20) throw Error("Unescaped control character in JSON string");
                    if (character == '\\')
                    {
                        if (position >= text.Length) throw Error("Unclosed JSON escape");
                        char escaped = text[position++];
                        switch (escaped)
                        {
                            case '"': output.Append('"'); break;
                            case '\\': output.Append('\\'); break;
                            case '/': output.Append('/'); break;
                            case 'b': output.Append('\b'); break;
                            case 'f': output.Append('\f'); break;
                            case 'n': output.Append('\n'); break;
                            case 'r': output.Append('\r'); break;
                            case 't': output.Append('\t'); break;
                            case 'u':
                                char first = ReadUnicodeEscape();
                                if (Char.IsHighSurrogate(first))
                                {
                                    if (position + 1 >= text.Length || text[position] != '\\' || text[position + 1] != 'u') throw Error("Unpaired escaped high surrogate");
                                    position += 2;
                                    char second = ReadUnicodeEscape();
                                    if (!Char.IsLowSurrogate(second)) throw Error("Unpaired escaped high surrogate");
                                    output.Append(first); output.Append(second);
                                }
                                else if (Char.IsLowSurrogate(first)) throw Error("Unpaired escaped low surrogate");
                                else output.Append(first);
                                break;
                            default: throw Error("Invalid JSON escape");
                        }
                    }
                    else if (Char.IsHighSurrogate(character))
                    {
                        if (position >= text.Length || !Char.IsLowSurrogate(text[position])) throw Error("Unpaired high surrogate");
                        output.Append(character); output.Append(text[position++]);
                    }
                    else if (Char.IsLowSurrogate(character)) throw Error("Unpaired low surrogate");
                    else output.Append(character);
                }
                throw Error("Unclosed JSON string");
            }
            private char ReadUnicodeEscape()
            {
                if (position + 4 > text.Length) throw Error("Incomplete Unicode escape");
                int result = 0;
                for (int index = 0; index < 4; index++)
                {
                    char character = text[position++];
                    int digit;
                    if (character >= '0' && character <= '9') digit = character - '0';
                    else if (character >= 'A' && character <= 'F') digit = character - 'A' + 10;
                    else if (character >= 'a' && character <= 'f') digit = character - 'a' + 10;
                    else throw Error("Invalid Unicode escape");
                    result = result * 16 + digit;
                }
                return (char)result;
            }
            private JsonNumber ReadNumber()
            {
                int first = position;
                while (position < text.Length)
                {
                    char character = text[position];
                    if (character == ',' || character == '}' || character == ']' || IsWhite(character)) break;
                    position++;
                }
                string lexeme = text.Substring(first, position - first);
                if (!IsNumberToken(lexeme)) throw Error("Invalid JSON number");
                return new JsonNumber(lexeme);
            }
            private void ReadLiteral(string literal)
            {
                if (position + literal.Length > text.Length || String.CompareOrdinal(text, position, literal, 0, literal.Length) != 0) throw Error("Invalid JSON literal");
                position += literal.Length;
            }
            private void SkipWhite() { while (position < text.Length && IsWhite(text[position])) position++; }
            private static bool IsWhite(char character) { return character == ' ' || character == '\t' || character == '\r' || character == '\n'; }
            private bool Take(char character)
            {
                if (position < text.Length && text[position] == character) { position++; return true; }
                return false;
            }
            private FormatException Error(string message)
            {
                return new FormatException(message + " at JSON character " + position.ToString(CultureInfo.InvariantCulture) + ".");
            }
        }
    }
}
