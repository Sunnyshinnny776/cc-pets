#import "CCPetsJSON.h"

@implementation CCPetsJSONObject {
    NSMutableArray<NSString *> *_keys;
    NSMutableDictionary<NSString *, id> *_values;
}

- (instancetype)init {
    if ((self = [super init])) {
        _keys = [NSMutableArray array];
        _values = [NSMutableDictionary dictionary];
    }
    return self;
}

- (NSArray<NSString *> *)keys {
    return [_keys copy];
}

- (id)objectForKeyedSubscript:(NSString *)key {
    return _values[key];
}

- (void)setObject:(id)value forKeyedSubscript:(NSString *)key {
    if (!_values[key]) [_keys addObject:key];
    _values[key] = value;
}

// 浅拷贝，对应 JS 的 { ...object }。
- (id)copyWithZone:(NSZone *)zone {
    CCPetsJSONObject *copy = [CCPetsJSONObject new];
    for (NSString *key in _keys) copy[key] = _values[key];
    return copy;
}

@end

@implementation CCPetsJSONNumber

- (instancetype)initWithLiteral:(NSString *)literal {
    if ((self = [super init])) _literal = [literal copy];
    return self;
}

@end

// 按 UTF-16 码元解析，和 JS 字符串的模型一致：\uD800 这类孤立代理项也能原样保留。
typedef struct {
    const unichar *characters;
    NSUInteger length;
    NSUInteger index;
    NSUInteger depth;
    NSString *error;
} JSONParser;

static const NSUInteger JSONMaximumDepth = 512;

static void JSONFail(JSONParser *parser, NSString *reason) {
    if (!parser->error) {
        parser->error = [NSString stringWithFormat:@"%@ at position %lu", reason, (unsigned long)parser->index];
    }
}

static void JSONSkipWhitespace(JSONParser *parser) {
    while (parser->index < parser->length) {
        unichar character = parser->characters[parser->index];
        if (character != ' ' && character != '\t' && character != '\n' && character != '\r') return;
        parser->index++;
    }
}

static BOOL JSONConsumeLiteral(JSONParser *parser, NSString *literal) {
    NSUInteger length = literal.length;
    if (parser->index + length > parser->length) return NO;
    for (NSUInteger offset = 0; offset < length; offset++) {
        if (parser->characters[parser->index + offset] != [literal characterAtIndex:offset]) return NO;
    }
    parser->index += length;
    return YES;
}

static int JSONHexValue(unichar character) {
    if (character >= '0' && character <= '9') return character - '0';
    if (character >= 'a' && character <= 'f') return character - 'a' + 10;
    if (character >= 'A' && character <= 'F') return character - 'A' + 10;
    return -1;
}

static NSString *JSONParseString(JSONParser *parser) {
    parser->index++;
    NSMutableString *result = [NSMutableString string];
    while (parser->index < parser->length) {
        unichar character = parser->characters[parser->index++];
        if (character == '"') return result;
        if (character < 0x20) {
            parser->index--;
            JSONFail(parser, @"Bad control character in string literal");
            return nil;
        }
        if (character != '\\') {
            [result appendFormat:@"%C", character];
            continue;
        }
        if (parser->index >= parser->length) break;
        unichar escape = parser->characters[parser->index++];
        switch (escape) {
            case '"': [result appendString:@"\""]; break;
            case '\\': [result appendString:@"\\"]; break;
            case '/': [result appendString:@"/"]; break;
            case 'b': [result appendString:@"\b"]; break;
            case 'f': [result appendString:@"\f"]; break;
            case 'n': [result appendString:@"\n"]; break;
            case 'r': [result appendString:@"\r"]; break;
            case 't': [result appendString:@"\t"]; break;
            case 'u': {
                if (parser->index + 4 > parser->length) {
                    JSONFail(parser, @"Bad Unicode escape");
                    return nil;
                }
                unichar value = 0;
                for (NSUInteger offset = 0; offset < 4; offset++) {
                    int digit = JSONHexValue(parser->characters[parser->index + offset]);
                    if (digit < 0) {
                        JSONFail(parser, @"Bad Unicode escape");
                        return nil;
                    }
                    value = (unichar)(value * 16 + digit);
                }
                parser->index += 4;
                [result appendFormat:@"%C", value];
                break;
            }
            default:
                parser->index--;
                JSONFail(parser, @"Bad escaped character");
                return nil;
        }
    }
    JSONFail(parser, @"Unterminated string");
    return nil;
}

static BOOL JSONIsDigit(JSONParser *parser) {
    if (parser->index >= parser->length) return NO;
    unichar character = parser->characters[parser->index];
    return character >= '0' && character <= '9';
}

static CCPetsJSONNumber *JSONParseNumber(JSONParser *parser) {
    NSUInteger start = parser->index;
    if (parser->characters[parser->index] == '-') parser->index++;
    if (!JSONIsDigit(parser)) {
        JSONFail(parser, @"No number after minus sign");
        return nil;
    }
    if (parser->characters[parser->index] == '0') {
        parser->index++;
    } else {
        while (JSONIsDigit(parser)) parser->index++;
    }
    if (parser->index < parser->length && parser->characters[parser->index] == '.') {
        parser->index++;
        if (!JSONIsDigit(parser)) {
            JSONFail(parser, @"Unterminated fractional number");
            return nil;
        }
        while (JSONIsDigit(parser)) parser->index++;
    }
    if (parser->index < parser->length &&
        (parser->characters[parser->index] == 'e' || parser->characters[parser->index] == 'E')) {
        parser->index++;
        if (parser->index < parser->length &&
            (parser->characters[parser->index] == '+' || parser->characters[parser->index] == '-')) {
            parser->index++;
        }
        if (!JSONIsDigit(parser)) {
            JSONFail(parser, @"Exponent part is missing a number");
            return nil;
        }
        while (JSONIsDigit(parser)) parser->index++;
    }
    NSString *literal = [NSString stringWithCharacters:parser->characters + start length:parser->index - start];
    return [[CCPetsJSONNumber alloc] initWithLiteral:literal];
}

static id JSONParseValue(JSONParser *parser);

static id JSONParseArray(JSONParser *parser) {
    parser->index++;
    NSMutableArray *array = [NSMutableArray array];
    JSONSkipWhitespace(parser);
    if (parser->index < parser->length && parser->characters[parser->index] == ']') {
        parser->index++;
        return array;
    }
    while (YES) {
        id value = JSONParseValue(parser);
        if (!value) return nil;
        [array addObject:value];
        JSONSkipWhitespace(parser);
        if (parser->index >= parser->length) break;
        unichar character = parser->characters[parser->index++];
        if (character == ']') return array;
        if (character != ',') {
            parser->index--;
            JSONFail(parser, @"Expected ',' or ']' after array element");
            return nil;
        }
    }
    JSONFail(parser, @"Unterminated array");
    return nil;
}

static id JSONParseObject(JSONParser *parser) {
    parser->index++;
    CCPetsJSONObject *object = [CCPetsJSONObject new];
    JSONSkipWhitespace(parser);
    if (parser->index < parser->length && parser->characters[parser->index] == '}') {
        parser->index++;
        return object;
    }
    while (YES) {
        JSONSkipWhitespace(parser);
        if (parser->index >= parser->length || parser->characters[parser->index] != '"') {
            JSONFail(parser, @"Expected double-quoted property name");
            return nil;
        }
        NSString *key = JSONParseString(parser);
        if (!key) return nil;
        JSONSkipWhitespace(parser);
        if (parser->index >= parser->length || parser->characters[parser->index] != ':') {
            JSONFail(parser, @"Expected ':' after property name");
            return nil;
        }
        parser->index++;
        id value = JSONParseValue(parser);
        if (!value) return nil;
        object[key] = value;
        JSONSkipWhitespace(parser);
        if (parser->index >= parser->length) break;
        unichar character = parser->characters[parser->index++];
        if (character == '}') return object;
        if (character != ',') {
            parser->index--;
            JSONFail(parser, @"Expected ',' or '}' after property value");
            return nil;
        }
    }
    JSONFail(parser, @"Unterminated object");
    return nil;
}

static id JSONParseValue(JSONParser *parser) {
    JSONSkipWhitespace(parser);
    if (parser->index >= parser->length) {
        JSONFail(parser, @"Unexpected end of JSON input");
        return nil;
    }
    unichar character = parser->characters[parser->index];
    if (character == '{' || character == '[') {
        if (++parser->depth > JSONMaximumDepth) {
            JSONFail(parser, @"Nesting too deep");
            return nil;
        }
        id value = character == '{' ? JSONParseObject(parser) : JSONParseArray(parser);
        parser->depth--;
        return value;
    }
    if (character == '"') return JSONParseString(parser);
    if (character == '-' || (character >= '0' && character <= '9')) return JSONParseNumber(parser);
    if (JSONConsumeLiteral(parser, @"true")) return @YES;
    if (JSONConsumeLiteral(parser, @"false")) return @NO;
    if (JSONConsumeLiteral(parser, @"null")) return NSNull.null;
    JSONFail(parser, [NSString stringWithFormat:@"Unexpected token '%C'", character]);
    return nil;
}

id CCPetsJSONParse(NSData *data, NSString **errorMessage) {
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!text) {
        if (errorMessage) *errorMessage = @"File is not valid UTF-8";
        return nil;
    }
    // 编辑器偶尔会写入 BOM。它不属于 JSON，跳过比整份配置拒收更合理。
    if ([text hasPrefix:@"﻿"]) text = [text substringFromIndex:1];
    NSUInteger length = text.length;
    unichar *characters = malloc(MAX(length, 1) * sizeof(unichar));
    [text getCharacters:characters range:NSMakeRange(0, length)];
    JSONParser parser = {characters, length, 0, 0, nil};
    id value = JSONParseValue(&parser);
    if (value) {
        JSONSkipWhitespace(&parser);
        if (parser.index < parser.length) {
            JSONFail(&parser, @"Unexpected non-whitespace character after JSON");
            value = nil;
        }
    }
    free(characters);
    if (!value && errorMessage) *errorMessage = parser.error ?: @"Invalid JSON";
    return value;
}

// 与 JSON.stringify 的转义规则一致：只转义引号、反斜杠和控制字符，孤立代理项写成 \uXXXX，
// 其余（包括中文、/、U+2028）原样输出。
static void JSONAppendString(NSMutableString *output, NSString *string) {
    [output appendString:@"\""];
    NSUInteger length = string.length;
    for (NSUInteger index = 0; index < length; index++) {
        unichar character = [string characterAtIndex:index];
        switch (character) {
            case '"': [output appendString:@"\\\""]; continue;
            case '\\': [output appendString:@"\\\\"]; continue;
            case '\b': [output appendString:@"\\b"]; continue;
            case '\f': [output appendString:@"\\f"]; continue;
            case '\n': [output appendString:@"\\n"]; continue;
            case '\r': [output appendString:@"\\r"]; continue;
            case '\t': [output appendString:@"\\t"]; continue;
            default: break;
        }
        if (character < 0x20) {
            [output appendFormat:@"\\u%04x", character];
        } else if (CFStringIsSurrogateHighCharacter(character) && index + 1 < length &&
                   CFStringIsSurrogateLowCharacter([string characterAtIndex:index + 1])) {
            [output appendFormat:@"%C%C", character, [string characterAtIndex:index + 1]];
            index++;
        } else if (CFStringIsSurrogateHighCharacter(character) || CFStringIsSurrogateLowCharacter(character)) {
            [output appendFormat:@"\\u%04x", character];
        } else {
            [output appendFormat:@"%C", character];
        }
    }
    [output appendString:@"\""];
}

static void JSONAppendValue(NSMutableString *output, id value, NSString *indent) {
    NSString *inner = [indent stringByAppendingString:@"  "];
    if ([value isKindOfClass:CCPetsJSONObject.class]) {
        CCPetsJSONObject *object = value;
        NSArray<NSString *> *keys = object.keys;
        if (keys.count == 0) {
            [output appendString:@"{}"];
            return;
        }
        [output appendString:@"{\n"];
        [keys enumerateObjectsUsingBlock:^(NSString *key, NSUInteger index, BOOL *stop) {
            [output appendString:inner];
            JSONAppendString(output, key);
            [output appendString:@": "];
            JSONAppendValue(output, object[key], inner);
            [output appendString:index + 1 < keys.count ? @",\n" : @"\n"];
        }];
        [output appendFormat:@"%@}", indent];
    } else if ([value isKindOfClass:NSArray.class]) {
        NSArray *array = value;
        if (array.count == 0) {
            [output appendString:@"[]"];
            return;
        }
        [output appendString:@"[\n"];
        [array enumerateObjectsUsingBlock:^(id element, NSUInteger index, BOOL *stop) {
            [output appendString:inner];
            JSONAppendValue(output, element, inner);
            [output appendString:index + 1 < array.count ? @",\n" : @"\n"];
        }];
        [output appendFormat:@"%@]", indent];
    } else if ([value isKindOfClass:NSString.class]) {
        JSONAppendString(output, value);
    } else if ([value isKindOfClass:CCPetsJSONNumber.class]) {
        [output appendString:((CCPetsJSONNumber *)value).literal];
    } else if ([value isKindOfClass:NSNumber.class]) {
        if (CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) {
            [output appendString:[value boolValue] ? @"true" : @"false"];
        } else {
            [output appendString:[value stringValue]];
        }
    } else {
        [output appendString:@"null"];
    }
}

NSString *CCPetsJSONStringify(id value) {
    NSMutableString *output = [NSMutableString string];
    JSONAppendValue(output, value, @"");
    return output;
}
