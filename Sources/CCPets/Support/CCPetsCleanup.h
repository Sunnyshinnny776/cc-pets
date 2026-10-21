#import <Foundation/Foundation.h>

// 启动时只清理已经过期且不再有展示价值的临时状态。
void PruneStaleRuntimeState(void);

// clean 删除可重建缓存；purge 额外删除历史、更新配置和用户偏好。
int CleanCCPetsData(BOOL purge);

// cc-pets paths / doctor 用：各类数据的实际路径（已套用环境变量覆盖）与桌宠是否在运行。
// 台词路径在 CCPetsPhrases 里，由 main.m 补上，免得只链接清理模块的测试也得带上整个词库。
NSDictionary<NSString *, id> *CCPetsDataPaths(void);
