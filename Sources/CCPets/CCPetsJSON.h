#import <Foundation/Foundation.h>

// 保序 JSON，用于改写用户自己的配置文件（~/.claude/settings.json、~/.codex/hooks.json）。
// NSJSONSerialization 不保留键顺序，输出格式也和 JSON.stringify 不同（"key" : value、转义 /），
// 拿它回写会把用户的文件整个打乱。这里的约定与原先 Node 安装器的 JSON.parse + JSON.stringify(…, null, 2)
// 一致：对象按键的首次出现顺序输出，重复键后者覆盖前者的值但不改变位置。
//
// 值的表示：对象 CCPetsJSONObject、数组 NSMutableArray、字符串 NSString、null NSNull、
// 布尔 @YES/@NO、解析出的数字 CCPetsJSONNumber（保留原文字面量，不经过 double 往返）。
// 代码里新建的数字可以直接用非布尔的 NSNumber；普通 NSDictionary 也能写出，键按字母序排列。

@interface CCPetsJSONObject : NSObject <NSCopying>
@property (nonatomic, readonly) NSArray<NSString *> *keys;
- (id)objectForKeyedSubscript:(NSString *)key;
// 已有的键原位替换值，新键追加到末尾，与 JS 对象的属性顺序规则相同。
- (void)setObject:(id)value forKeyedSubscript:(NSString *)key;
- (void)removeObjectForKey:(NSString *)key;
@end

@interface CCPetsJSONNumber : NSObject
@property (nonatomic, readonly, copy) NSString *literal;
@end

// 解析失败返回 nil，并通过 errorMessage 给出出错位置。
id CCPetsJSONParse(NSData *data, NSString **errorMessage);
// 等价于 JSON.stringify(value, null, 2)。
NSString *CCPetsJSONStringify(id value);
