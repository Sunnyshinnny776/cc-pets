#import <Foundation/Foundation.h>
#import "CCPetsVersion.h"

// 更新弹窗的说明来自 GitHub Release 描述。Release 是中英双语、带图片和代码块的 Markdown，
// 弹窗只放得下三条纯文本要点，多出来的用「…」示意。

static BOOL Expect(NSString *label, NSString *body, NSArray<NSString *> *expected, BOOL expectTruncated) {
    BOOL truncated = NO;
    NSArray<NSString *> *actual = ReleaseNoteHighlights(body, 3, 20, &truncated);
    if ([actual isEqualToArray:expected] && truncated == expectTruncated) return YES;
    NSLog(@"%@: 得到 %@ truncated=%d，期望 %@ truncated=%d", label, actual, truncated,
        expected, expectTruncated);
    return NO;
}

int main(void) {
    @autoreleasepool {
        BOOL ok = YES;
        ok &= Expect(@"空描述", @"", @[], NO);
        ok &= Expect(@"nil", nil, @[], NO);
        ok &= Expect(@"只有正文没有列表", @"一个小修复版本。\n\n感谢反馈。", @[], NO);
        ok &= Expect(@"去掉 Markdown 标记",
            @"- 新增 **玻璃** 主题\n* 修复 `cc-pets` 崩溃\n1. 见 [文档](https://x.y)\n", 
            @[@"新增 玻璃 主题", @"修复 cc-pets 崩溃", @"见 文档"], NO);
        ok &= Expect(@"超过三条只取前三条",
            @"- a\n- b\n- c\n- d\n", @[@"a", @"b", @"c"], YES);
        ok &= Expect(@"正好三条不算截断",
            @"- a\n- b\n- c\n", @[@"a", @"b", @"c"], NO);
        ok &= Expect(@"单条过长截断",
            @"- 一二三四五六七八九十一二三四五六七八九十多出来的\n",
            @[@"一二三四五六七八九十一二三四五六七八九十…"], NO);
        ok &= Expect(@"跳过代码块和嵌套子项",
            @"```bash\n- 不是列表\n```\n- 顶层\n  - 子项\n", @[@"顶层"], NO);
        ok &= Expect(@"双语只取简体中文段",
            @"![cover](a.png)\n\n## English\n\n- English item\n\n## 简体中文\n\n### 新功能\n\n- 中文一\n- 中文二\n",
            @[@"中文一", @"中文二"], NO);
        ok &= Expect(@"简体中文段之后的同级标题不算",
            @"## 简体中文\n- 中文\n## 其他\n- 不要\n", @[@"中文"], NO);
        if (!ok) return 1;
    }
    return 0;
}
