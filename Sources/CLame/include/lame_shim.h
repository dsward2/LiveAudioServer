/*
 * LiveAudioServer — https://github.com/dsward2/LiveAudioServer
 *
 * Copyright (c)2026 by Douglas Ward - Conway, Arkansas US
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
 * implied. See the License for the specific language governing
 * permissions and limitations under the License.
 */

#if __has_include(<lame/lame.h>)
#include <lame/lame.h>
#elif __has_include(<lame.h>)
#include <lame.h>
#else
#error "Unable to find libmp3lame headers. Install the 'lame' package and ensure its headers are on the include path."
#endif
