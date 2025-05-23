module xml;

import std::io;
import std::core;
import std::core::dstring;
import std::math;
import std::collections::list;
import std::collections::map;
import std::ascii;

alias Attribute = HashMap{String, String};
alias NodePointers = List{Node*};
alias NodeList = List{Node};

struct Node {
	String name;
	String value;
	String header;
	Attribute attributes;
	NodeList children;
}

struct Parser {
	Allocator allocator;
	InStream stream;
	DString buffer;
	XMLToken token;
	Node* active_node;
	NodePointers open_nodes;
	usz line;
}

faultdef EOF, UNEXPECTED_CHARACTER, FILE_NOT_FOUND;

enum XMLToken @local
{
	START_TAG,
	CLOSE_TAG,
	END_TAG,
	ATTRIBUTE,
	VALUE,
	HEADER,
}

alias NodeSearch = fn bool (Node);
alias ParserSearch = fn bool (char value);

fn void Node.find(self, NodeSearch search_fn, NodeList* cache) {
	if (search_fn(self)) cache.push(self);
	foreach (child: self.children) child.find(search_fn, cache);
}

fn void? Parser.advance(&self)
{
	char c;
	while WS: (c = self.stream.read_byte()!)
	{
		switch (c)
		{
			case '\n':
				self.line++;
				nextcase;
			case ' ':
			case '\t':
			case '\r':
			case '\v':
				continue;
			default:
				break WS;
		}
	}

	switch (true)
	{
		case c == '<' && self.peek(fn (character) => character == '!' || character == '?')! : {
			self.token = HEADER;
			self.stream.seek(1, CURSOR)!;
			// Parses header value
			while (self.peek(fn (character) => character != '>')!) {
				self.buffer.append(self.stream.read_byte()!);
			}
			
			break;
		}
		case c == '<' && self.peek(fn (character) => character != '/')!: {
			self.token = START_TAG;			
			// Parser tag name
			while (self.peek(fn (character) => character != '>' && character != ' ')!) {
				self.buffer.append(self.stream.read_byte()!);
			}
			break;
		}
		case c == '>' && (self.token == START_TAG || self.token == ATTRIBUTE || self.token == HEADER): {
			self.token = END_TAG;
			break;
		}
		case c == '/' && self.peek(fn (character) => character == '>')!: {
			self.token = CLOSE_TAG;
			self.seek(fn (character) => character == '>')!;
			break;
		}
		case c == '<' && self.peek(fn (character) => character == '/')!: {
			self.token = CLOSE_TAG;
			self.seek(fn (character) => character == '>')!;
			break;
		}
		case std::ascii::is_print(c) && (self.token == START_TAG || self.token == ATTRIBUTE): {
			self.token = ATTRIBUTE;
			//Parser attribute value
			usz size = self.seek(fn (character) => character == '"', skip: 1, return_pos: true)!;
			for (uint i = 0; i < size + 1; i++) self.buffer.append(self.stream.read_byte()!);
			break;
		}
		case std::ascii::is_print(c): {
			self.token = VALUE;
			self.stream.seek(-1, CURSOR)!;
			// Parses value
			while (self.peek(fn (character) => character != '<')!) {
				self.buffer.append(self.stream.read_byte()!);
			}
			
			break;
		}
		default:
			io::printfn("not found char %c", c);
			return UNEXPECTED_CHARACTER?;
	}
}



fn usz? Parser.seek(&self, ParserSearch search, uint skip = 0, bool return_pos = false)
{
	usz offset;
	uint skipped = 0;
	char c;
	// Find the char
	while (c = self.stream.read_byte()!) {
		offset++;
		if (search(c)) {
			if (skipped == skip) {break;}
			else {
				skipped += 1; 
				continue;
			};
		};
	};

	if (return_pos) self.stream.seek(-(offset + 1), Seek.CURSOR)!;
	return offset;
}

fn bool? Parser.peek(&self, ParserSearch search)
{
	bool response = search(self.stream.read_byte()!);
	// Set stream back to start pos
	self.stream.seek(-1, CURSOR)!;
	return response;
}


fn Node? parse_string(String s, Allocator allocator = allocator::heap()) => parse((ByteReader){}.init(s), allocator);
fn Node? load_file (String path, Allocator allocator = allocator::heap()) {
    File? file = file::open(path, "r");
    defer file.close()!!;

    if (catch err = file) {
        io::printfn("Failed to find the xml file");
        return FILE_NOT_FOUND?;
    }

    return parse(&file, allocator);
}


fn Node? parse(InStream s, Allocator allocator = allocator::heap())
{
	Node root_node;
	Parser parser = { .buffer = dstring::new_with_capacity(allocator,2024), .stream = s, .allocator = allocator, .active_node = &root_node};
	defer parser.free();

	while (try parser.advance()) {
			switch (parser.token) {
				case START_TAG: {
					if (parser.open_nodes.len() == 0) {
						// Root node
						parser.active_node.name = parser.buffer.copy_str(allocator);
					} else {
						// Push node as child
						Node* parent_node = parser.open_nodes[parser.open_nodes.len() - 1];

						parent_node.children.push((Node) {
							.name = parser.buffer.copy_str(allocator)
						});
					
						parser.active_node = &parent_node.children[parent_node.children.len() - 1];
					}
					parser.open_nodes.push(parser.active_node);
					parser.buffer.clear();
				}
				case END_TAG: {}
				case CLOSE_TAG: {
					if (parser.open_nodes.len() > 0) parser.open_nodes.pop()!;
				}
				case VALUE: {
					if (parser.open_nodes.len() - 1 > 0) {
						Node* node = parser.open_nodes[parser.open_nodes.len() - 1];
						node.value = parser.buffer.copy_str(allocator);
					}
					parser.buffer.clear();
				}
				case ATTRIBUTE: {
					String data = parser.buffer.str_view();
					usz split_index = data.index_of_char('=')!;
					bool empty_value = (data.len - split_index) <= 3;

					// Add attribute to hashmap
					parser.active_node.attributes.set(data[0..split_index - 1].copy(allocator), empty_value ? "" : data[split_index + 2..parser.buffer.len() - 2].copy(allocator));
					parser.buffer.clear();
				}
				case HEADER: {
					parser.active_node.header = parser.buffer.copy_str(allocator);
					parser.buffer.clear();
				}
				default: {
					break;
				}
			}
	}

	return root_node;
}


fn void Parser.free(&self)
{
	self.buffer.free();
	self.open_nodes.free();
}

fn void Node.free(&self,Allocator allocator = allocator::heap())
{
	foreach (child: self.children) child.free();
	self.attributes.free();
	self.children.free();
	self.name.free(allocator);
	self.value.free(allocator);
	self.header.free(allocator);
}

