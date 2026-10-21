#import <Foundation/Foundation.h>

// 仅供生成 README 截图的离屏渲染，不参与桌宠运行时。
int RenderQuotaDashboard(NSString *path);
int RenderAgentStatusCard(NSString *path);
int RenderMenuSwitches(NSString *path);
// 把 PetView 的每一格（rowCount 行 × 8 帧）逐格渲染拼成一张大图，用于渲染改造的
// 逐字节等价校验。上面三个命令一格宠物都不画，改坏 PetView 它们照样一致。
int RenderPetSheet(NSString *path, NSString *sheetPath, NSInteger rowCount);
