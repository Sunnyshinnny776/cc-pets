#import <Cocoa/Cocoa.h>
#import "CCPetsMenuBarSummary.h"

// 菜单栏图标：描边的终端窗口，颜色随状态变化；符号只有等待审批时换成 •••，其余都是 >_：
//
//   待机    原色（template，系统按菜单栏明暗显示白或黑）  >_
//   工作中  系统蓝                                          >_
//   审批    系统橙                                          •••
//   完成    系统绿                                          >_
//   失败    系统红                                          >_
//
// 单色线条：16pt 下双色、渐变和发光都看不出来，template 也只认单色。框内透出菜单栏底色。
extern const NSSize CCPetsMenuBarIconSize;

// 每次调用都会新建图片，调用方按色调缓存（系统色是动态色，绘制时按菜单栏外观解析，缓存不会过期）。
NSImage *CCPetsMenuBarIconImage(CCPetsMenuBarIconTone tone);
