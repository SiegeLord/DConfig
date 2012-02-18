module dconfig;

import TextUtil = tango.text.Util;
import Array = tango.core.Array;
import Float = tango.text.convert.Float;
import tango.core.Variant;
import tango.text.convert.Format;
import tango.io.device.File;
import tango.io.FilePath;
import tango.io.Path;
import tango.text.json.JsonEscape;

alias const(char)[] cstring;

enum EToken
{
	String,
	Real,
	Boolean,
	SemiColon,
	LeftBrace,
	RightBrace,
	EOF
}

struct SToken
{
	cstring String;
	size_t Line;
	EToken Type;
}

class CDConfigException : Exception
{
	this(immutable(char)[] msg, cstring filename, size_t line)
	{
		super(Format("{}({}): {}", filename, line, msg).idup);
	}
}

struct STokenizer
{
	this(cstring filename, cstring src)
	{
		FileName = filename;
		Source = src;
		CurLine = 1;
	}
	
	bool IsDigit(char c)
	{
		return c >= '0' && c <= '9';
	}
	
	bool IsDigitStart(char c)
	{
		return IsDigit(c) || c == '+' || c == '-';
	}
	
	bool IsAlpha(char c)
	{
		return 
			(c >= 'a' && c <= 'z') 
			|| (c >= 'A' && c <= 'Z')
			|| (c == '_');
	}
	
	bool IsAlphaNumeric(char c)
	{
		return IsAlpha(c) || IsDigit(c);
	}
	
	cstring ConsumeComment(cstring src)
	{
		if(src.length < 2)
			return src;
		
		if(src[0] == '/')
		{
			if(src[1] == '/')
			{
				//TODO: Windows type newlines
				auto end = Array.find(src, '\n');
				
				if(end != src.length)
					CurLine++;
					
				return src[end + 1..$];
			}
			else if(src[1] == '*')
			{
				/*
				 * These comments are nesting
				 */
				size_t comment_num = 1;
				size_t comment_end = 2;
				
				size_t lines_passed = 0;
				
				do
				{
					auto old_end = comment_end;
					
					comment_end = TextUtil.locatePattern(src, "*/", old_end);
					if(comment_end == src.length)
						throw new CDConfigException("Unexpected EOF when parsing a multiline comment", FileName, CurLine);
					
					comment_end += 2; //Past the ending * /
					comment_num -= 1; //Closed one
					
					comment_num += TextUtil.count(src[old_end..comment_end], "/*");
					
					//TODO: Windows type newlines
					lines_passed += TextUtil.count(src[old_end..comment_end], "\n");
				} while(comment_num > 0);
				
				CurLine += lines_passed;
			
				return src[comment_end..$];
			}
		}
		return src;
	}
	
	/*
	 * Trims leading whitespace while counting newlines
	 */
	cstring Trim(cstring source)
	{
		auto head = source.ptr,
		tail = head + source.length;

		while(head < tail && TextUtil.isSpace(*head))
		{
			//TODO: Windows type newlines
			if(*head == '\n')
				CurLine++;
			++head;
		}

		return head[0..tail - head];
	}
	
	bool ConsumeString(cstring src, ref size_t end)
	{
		size_t idx = 0;
		size_t line = CurLine;
			
		if(src[0] == '"')
		{
			idx++;
			while(true)
			{
				if(idx == src.length)
					throw new CDConfigException("Unexpected EOF when parsing a string", FileName, CurLine);
				else if(src[idx] == '"' && src[idx - 1] != '\\')
					break;
				//TODO: Windows type newlines
				else if(src[idx] == '\n')
					line++;
					
				idx++;
			}
			idx++;
		}
		else if(src[0] == '\'')
		{
			idx++;
			int num_quotes = 1;
			while(src[idx] == '\'')
			{
				num_quotes++;
				idx++;
			}
			if(src[idx] != '"')
				throw new CDConfigException(`Expected a double quote after one or more single quotes, not ` ~ src[idx], FileName, CurLine);
			idx++;
			
			int new_num_quotes = -1;
			bool searching = false;
			while(new_num_quotes != num_quotes)
			{
				if(idx == src.length)
					throw new CDConfigException("Unexpected EOF when parsing a string", FileName, CurLine);
				else if(src[idx] == '"')
					new_num_quotes = 0;
				else if(src[idx] == '\'' && new_num_quotes >= 0)
					new_num_quotes++;
				//TODO: Windows type newlines
				else if(src[idx] == '\n')
					line++;
				else
					new_num_quotes = -1;
				
				idx++;
			}
		}
		else if(IsAlpha(src[0]))
		{
			idx = Array.findIf(src, (char c) {return !IsAlphaNumeric(c);});
		}
		else
		{
			return false;
		}
		
		end = idx;
		CurLine = line;

		return true;
	}
	
	bool ConsumeBoolean(cstring src, ref size_t end)
	{
		end = Array.find(src, "true") + 4;
		if(end == 4)
			return true;
		end = Array.find(src, "false") + 5;
		if(end == 5)
			return true;
		return false;
	}
	
	bool ConsumeChar(cstring src, char c, ref size_t end)
	{
		if(src[0] == c)
		{
			end = 1;
			return true;
		}
		return false;
	}
	
	bool ConsumeInteger(cstring src, ref size_t end)
	{
		if(IsDigitStart(src[0]))
		{
			if(!IsDigit(src[0]) && (src.length < 2 || !IsDigit(src[1])))
				return false;

			auto cur_end = Array.findIf(src[1..$], (char c) {return !IsDigit(c);}) + 1;
			if(src[cur_end] == '.' || src[cur_end] == 'e' || src[cur_end] == 'E')
				return false;
				
			end = cur_end;
			return true;
		}
		return false;
	}
	
	bool ConsumeReal(cstring src, ref size_t end)
	{
		if(IsDigitStart(src[0]))
		{
			if(!IsDigit(src[0]) && (src.length < 2 || !IsDigit(src[1])))
				return false;

			auto cur_end = Array.findIf(src[1..$], (char c) {return !IsDigit(c);}) + 1;
			switch(src[cur_end])
			{
				case '.':
				{
					if(cur_end == src.length - 1 || !IsDigit(src[cur_end + 1]))
						return false;
					
					cur_end += Array.findIf(src[cur_end + 1..$], (char c) {return !IsDigit(c);}) + 1;
					if(src[cur_end] != 'e' && src[cur_end] != 'E')
						break;
					goto case;
				}
				case 'e':
				case 'E':
				{
					if(cur_end == src.length - 1 || !IsDigit(src[cur_end + 1]))
						return false;

					cur_end += Array.findIf(src[cur_end + 1..$], (char c) {return !IsDigit(c);}) + 1;
					
					break;
				}
				default:
			}
				
			end = cur_end;
			return true;
		}
		return false;
	}
	
	cstring ConvertString(cstring str)
	{
		if(str[0] == '"')
		{
			return unescape(str[1..$-1]);
		}
		else if(str[0] == '\'')
		{
			size_t idx = 1;
			size_t num_quotes = 1;
			while(str[idx] == '\'')
			{
				num_quotes++;
				idx++;
			}
			num_quotes++;
			
			return str[num_quotes..$-num_quotes];
		}
		else
		{
			return str;
		}
	}
	
	SToken Next()
	{
		SToken tok;
		
		/*
		 * Consume non-tokens
		 */
		bool changed = false;
		while(!changed)
		{
			Source = Trim(Source);
			
			auto old_len = Source.length;
			Source = ConsumeComment(Source);
			changed = old_len == Source.length;
		}
		
		/*
		 * Try interpreting a token
		 */
		if(Source.length > 0)
		{			
			size_t end = Source.length;

			if(ConsumeReal(Source, end))
				tok.Type = EToken.Real;
			else if(ConsumeBoolean(Source, end))
				tok.Type = EToken.Boolean;
			else if(ConsumeString(Source, end))
				tok.Type = EToken.String;
			else if(ConsumeChar(Source, ';', end))
				tok.Type = EToken.SemiColon;
			else if(ConsumeChar(Source, '{', end))
				tok.Type = EToken.LeftBrace;
			else if(ConsumeChar(Source, '}', end))
				tok.Type = EToken.RightBrace;
			else
				throw new CDConfigException("Invalid token! '" ~ Source[0] ~ "'", FileName, CurLine);
			
			tok.String = ConvertString(Source[0..end]);
			tok.Line = CurLine;
			Source = Source[end..$];
		}
		else
		{
			tok.Type = EToken.EOF;
		}
		return tok;
	}
	
	cstring FileName;
	size_t CurLine;
	cstring Source;
}

struct SParser
{
	this(cstring filename, cstring src)
	{
		Tokenizer = STokenizer(filename, src);
		NextToken = Tokenizer.Next();
		Advance();
	}
	
	@property
	bool EOF()
	{
		return CurToken.Type == EToken.EOF;
	}
	
	@property
	EToken Advance()
	{
		CurToken = NextToken;
		NextToken = Tokenizer.Next();
		CurLine = CurToken.Line;
		return Peek;
	}
	
	@property
	EToken Peek()
	{
		return CurToken.Type;
	}
	
	@property
	int PeekNext()
	{
		return NextToken.Type;
	}
	
	@property
	cstring FileName()
	{
		return Tokenizer.FileName;
	}
	
	SToken CurToken;
	SToken NextToken;
	size_t CurLine;
	STokenizer Tokenizer;
}

unittest
{
	auto src = 
	`
	''""''
	''"ab"'"''
	"a\t"
	0.1//
	5/*/**/*/
	-1.5e6
	abc
	true
	`;
	
	auto parser = SParser("", src);
	assert(parser.Peek == EToken.String && parser.CurToken.String == "", parser.CurToken.String);
	assert(parser.Advance == EToken.String && parser.CurToken.String == `ab"'`, parser.CurToken.String);
	assert(parser.Advance == EToken.String && parser.CurToken.String == "a\t", parser.CurToken.String);
	assert(parser.Advance == EToken.Real && parser.CurToken.String == `0.1`, parser.CurToken.String);
	assert(parser.Advance == EToken.Real && parser.CurToken.String == `5`, parser.CurToken.String);
	assert(parser.Advance == EToken.Real && parser.CurToken.String == `-1.5e6`, parser.CurToken.String);
	assert(parser.Advance == EToken.String && parser.CurToken.String == `abc`, parser.CurToken.String);
	assert(parser.Advance == EToken.Boolean && parser.CurToken.String == `true`, parser.CurToken.String);
}

struct SConfigNode
{
	this(uint type)
	{
		assert(type < MaxType);
		TypeVal = type;
	}
	
	SConfigNode opAssign(T)(T val)
	{
		static if(is(T == SConfigNode))
		{
			this.ChildrenVal = val.ChildrenVal;
			this.TypeVal = val.TypeVal;
			this.Storage = val.Storage;
		}
		else static if(is(T == bool))
		{
			if(Type == Empty || Type == Boolean)
			{
				TypeVal = Boolean;
				Storage.Boolean = val;
			}
			else
			{
				throw new Exception("Can only assign '" ~ T.stringof ~ "' to SConfigNode with type Boolean or Empty.");
			}
		}
		else static if(is(T : real) || is(T : uint) || is(T : int))
		{
			if(Type == Empty || Type == Real)
			{
				TypeVal = Real;
				Storage.Real = cast(real)val;
			}
			else
			{
				throw new Exception("Can only assign '" ~ T.stringof ~ "' to SConfigNode with type Real or Empty.");
			}
		}
		else static if(is(T : cstring))
		{
			if(Type == Empty || Type == String)
			{
				TypeVal = String;
				Storage.String = val;
			}
			else
			{
				throw new Exception("Can only assign '" ~ T.stringof ~ "' to SConfigNode with type String or Empty.");
			}
		}
		else
		{
			static assert(0, "Cannot store this type in SConfigNode.");
		}
		
		return this;
	}
	
	T Value(T)(T def = T.init, bool* is_def = null)
	{
		@property
		void set_def(bool val)
		{
			if(is_def !is null)
				*is_def = val;
		}
		
		static if(is(cstring : T))
		{
			if(Type == String)
			{
				set_def = false;
				return cast(T)Storage.String;
			}
		}
		else static if(is(T == bool))
		{
			if(Type == Boolean)
			{
				set_def = false;
				return cast(T)Storage.Boolean;
			}
		}
		else static if(is(real : T) || is(T : uint) || is(T : int))
		{
			if(Type == Real)
			{
				set_def = false;
				return cast(T)Storage.Real;
			}
		}
		else
		{
			static assert(0, "Cannot extract this type from SConfigNode");
		}
		
		set_def = true;
		return def;
	}
	
	T opCast(T)()
	{
		bool is_def;
		auto ret = Value!(T)(T.init, &is_def);
		
		cstring reason;
		switch(Type)
		{
			case Real:
				reason = "holds a real value.";
				break;
			case String:
				reason = "holds a string value.";
				break;
			case Boolean:
				reason = "holds a boolea value.";
				break;
			case Empty:
				reason = "is empty.";
				break;
			default:
		}
		
		if(is_def)
			throw new Exception("Cannot extract '" ~ T.stringof ~ "' from this node, it " ~ reason.idup);
	}
	
	bool opEquals(T)(T val)
	{
		enum type = ImplicitType!(T);
		if(type == Type)
		{
			static if(type == String)
			{
				return Storage.String == val;
			}
			else static if(type == Real)
			{
				return Storage.Real == cast(real)val;
			}
			else static if(type == Boolean)
			{
				return Storage.Boolean == val;
			}
			assert(0);
		}
		else
		{
			return false;
		}
	}
	
	struct SFilterFruct
	{
		SConfigNode Node;
		bool delegate(SConfigNode) Filter;

		int opApply(scope int delegate(ref SConfigNode) dg)
		{
			int ret = 0;
			foreach(child; Node.Children)
			{
				if(Filter(child))
				{
					if((ret = dg(child)) != 0)
						return ret;
				}
			}
			return ret;
		}
	}
	
	struct SValueFruct(T)
	{
		SConfigNode Node;
		T Value;

		int opApply(scope int delegate(ref SConfigNode) dg)
		{
			enum type = SConfigNode.ImplicitType!(T);
			int ret = 0;
			foreach(child; Node.Children)
			{
				if(child.Type == type || child == Value)
				{
					if((ret = dg(child)) != 0)
						return ret;
				}
			}
			return ret;
		}
	}
	
	struct STypeFruct
	{
		SConfigNode Node;
		uint Type;

		int opApply(scope int delegate(ref SConfigNode) dg)
		{
			int ret = 0;
			foreach(child; Node.Children)
			{
				if(child.Type == Type)
				{
					if((ret = dg(child)) != 0)
						return ret;
				}
			}
			return ret;
		}
	}
	
	SFilterFruct Filter(bool delegate(SConfigNode) filter)
	{
		return SFilterFruct(this, filter);
	}
	
	STypeFruct FilterByType(T)()
	{
		auto type = ImplicitType!(T);
		return FilterByType(type);
	}
	
	STypeFruct FilterByType()(uint type)
	{
		return STypeFruct(this, type);
	}
	
	SValueFruct!(T) FilterByValue(T)(T value)
	{
		return SValueFruct!(T)(this);
	}
	
	void opOpAssign(immutable(char)[] s : "~")(SConfigNode child)
	{
		ChildrenVal ~= child;
	}
	
	SConfigNode FirstByValue(T)(T value)
	{
		auto type = ImplicitType!(T);
		foreach(child; Children)
		{
			if(child.Type == type && child == value)
				return child;
		}
		return SConfigNode();
	}
	
	SConfigNode LastByValue(T)(T value)
	{
		auto type = ImplicitType!(T);
		foreach_reverse(child; Children)
		{
			if(child.Type == type && child == value)
			{
				return child;
			}
		}
		return SConfigNode();
	}
	
	SConfigNode FirstByType()(uint type)
	{
		foreach(child; Children)
		{
			if(child.Type == type)
				return child;
		}
		return SConfigNode();
	}
	
	SConfigNode FirstByType(T)()
	{
		return FirstByType(ImplicitType!(T));
	}
	
	SConfigNode LastByType()(uint type)
	{
		foreach_reverse(child; Children)
		{
			if(child.Type == type)
				return child;
		}
		return SConfigNode();
	}
	
	SConfigNode LastByType(T)()
	{
		return LastByType(ImplicitType!(T));
	}
	
	T ValueOf(T, K)(K key, T def = T.init, bool* is_def = null)
	{
		void set_def(bool val)
		{
			if(is_def !is null)
				*is_def = val;
		}
		
		auto key_node = LastByValue(key);
		if(key_node.IsEmpty)
		{
			set_def(true);
			return def;
		}
		
		auto val_node = key_node.LastByType!(T);
		if(val_node.IsEmpty)
		{
			set_def(true);
			return def;
		}
		
		return val_node.Value(def, is_def);
	}
	
	@property
	SConfigNode[] Children()
	{
		return ChildrenVal;
	}
	
	@property
	bool IsEmpty()
	{
		return Type == Empty;
	}
	
	@property
	int Type()
	{
		return TypeVal;
	}
	
	void Reset()
	{
		TypeVal = Empty;
	}
	
	enum : uint
	{
		Empty,
		Real,
		String,
		Boolean,
		MaxType
	}
protected:
	template ImplicitType(T)
	{
		static if(is(T : const(char)[]))
			enum uint ImplicitType = String;
		else static if(is(T : bool))
			enum uint ImplicitType = Boolean;
		else static if(is(T : real) || is(T : uint) || is(T : int))
			enum uint ImplicitType = Real;
		else
			static assert(0, "Cannot retrieve this type from SConfigNode.");
	}

	SConfigNode[] ChildrenVal;
	
	union UStorage
	{
		real Real;
		bool Boolean;
		cstring String;
	}
	
	UStorage Storage;
	uint TypeVal = Empty;
}

unittest
{
	SConfigNode node;
	node = 1;
	node.Reset();
	node = 1.0;
	node.Reset();
	node = "abc";
	bool failed = false;
	try
	{
		node = 1.0;
	}
	catch(Exception e)
	{
		failed = true;
	}
	assert(failed);
	
	static assert(SConfigNode.ImplicitType!(int) == SConfigNode.Real);
	static assert(SConfigNode.ImplicitType!(immutable(char)[]) == SConfigNode.String);
	static assert(SConfigNode.ImplicitType!(bool) == SConfigNode.Boolean);
}

SConfigNode LoadNode(SParser* parser)
{
	SConfigNode ret;
	
	@property
	SToken cur_token()
	{
		return parser.CurToken;
	}

	switch(parser.Peek)
	{
		case EToken.String:
			ret = cur_token.String;
			break;
		case EToken.Boolean:
			ret = cur_token.String == "true";
			break;
		case EToken.Real:
			ret = Float.toFloat(cur_token.String);
			break;
		default:
			throw new CDConfigException("Expected a string, boolean or real, not '" ~ cur_token.String.idup ~ "'.", parser.FileName, cur_token.Line);
	}
	
	final switch(parser.Advance)
	{
		case EToken.LeftBrace:
		{
			auto old_line = cur_token.Line;
			parser.Advance;
			while(parser.Peek != EToken.RightBrace)
			{
				if(parser.Peek == EToken.EOF)
					throw new CDConfigException("Unexpected EOF while parsing a composite.", parser.FileName, old_line);
				auto new_child = LoadNode(parser);
				assert(new_child.Type != SConfigNode.Empty);
				ret ~= new_child;
			}
			parser.Advance;
			break;
		}
		case EToken.EOF:
			throw new CDConfigException("Expected ';' not EOF.", parser.FileName, cur_token.Line);
			break;
		case EToken.RightBrace:
			throw new CDConfigException("Expected ';' not '}'.", parser.FileName, cur_token.Line);
			break;
		case EToken.SemiColon:
			parser.Advance;
			break;
		case EToken.String:
		case EToken.Real:
		case EToken.Boolean:
			auto new_child = LoadNode(parser);
			assert(new_child.Type != SConfigNode.Empty);
			ret ~= new_child;
			break;
	}
	
	return ret;
}

SConfigNode LoadConfig(const(char)[] filename, const(char)[] src = null)
{
	if(src is null)
		src = cast(char[])File.get(filename);
	
	auto parser = SParser(filename, src);
	
	SConfigNode root;
	
	while(parser.Peek != EToken.EOF)
	{
		auto child = LoadNode(&parser);
		assert(child.Type != SConfigNode.Empty);
		root ~= child;
	}
	
	return root;
}

unittest
{
	auto src = 
	`	1 2 3;
		a b c;
		true false;
		a
		{
			b;
			"b";
			'"b"';
		}
	`;
	
	auto root = LoadConfig("test", src);
	assert(root.Children.length == 4);
	
	size_t count = 0;
	foreach(node; root.FilterByType!(real))
		count++;
	assert(count == 1, Format("{}", count));
	
	count = 0;
	foreach(node; root.FilterByType(SConfigNode.String))
		count++;
	assert(count == 2, Format("{}", count));
	
	count = 0;
	foreach(node; root.FilterByType(SConfigNode.Boolean))
		count++;
	assert(count == 1, Format("{}", count));
	
	auto child = root.FirstByValue(1);
	assert(!child.IsEmpty);
	assert(child == 1);
	child = root.LastByValue("a");
	assert(!child.IsEmpty);
	assert(child == "a");
	auto str = child.Value!(cstring)();
	assert(str == "a");
	
	count = 0;
	foreach(node; child.FilterByValue("b"))
		count++;
	assert(count == 3, Format("{}", count));
	
	assert(root.LastByValue("a").LastByType!(cstring) == "b");
	
	bool is_def;
	cstring value = root.ValueOf!(cstring, string)("a", null, &is_def);
	assert(is_def == false);
	assert(value == "b", value);
	assert(root.ValueOf!(real)(1) == 2);
	assert(root.ValueOf!(cstring)(1) == null);
}
