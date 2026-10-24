// SPDX-License-Identifier: GPL-2.0-or-later
// 화면 문구 번역: en.lproj/Localizable.strings에 있으면 영어, 없으면 원문(한국어)
#pragma once
#import <Foundation/Foundation.h>
#define WSL(s) [NSBundle.mainBundle localizedStringForKey:(s) value:(s) table:nil]
