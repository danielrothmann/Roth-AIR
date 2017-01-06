/*
  ==============================================================================

   This file is part of the juce_core module of the JUCE library.
   Copyright (c) 2015 - ROLI Ltd.

   Permission to use, copy, modify, and/or distribute this software for any purpose with
   or without fee is hereby granted, provided that the above copyright notice and this
   permission notice appear in all copies.

   THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES WITH REGARD
   TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS. IN
   NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL
   DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER
   IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR IN
   CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

   ------------------------------------------------------------------------------

   NOTE! This permissive ISC license applies ONLY to files within the juce_core module!
   All other JUCE modules are covered by a dual GPL/commercial license, so if you are
   using any other modules, be sure to check that you also comply with their license.

   For more details, visit www.juce.com

  ==============================================================================
*/

#ifndef JUCE_TARGETPLATFORM_H_INCLUDED
#define JUCE_TARGETPLATFORM_H_INCLUDED

//==============================================================================
/*  This file figures out which platform is being built, and defines some macros
    that the rest of the code can use for OS-specific compilation.

    Macros that will be set here are:

    - One of JUCE_WINDOWS, JUCE_MAC JUCE_LINUX, JUCE_IOS, JUCE_ANDROID, etc.
    - Either JUCE_32BIT or JUCE_64BIT, depending on the architecture.
    - Either JUCE_LITTLE_ENDIAN or JUCE_BIG_ENDIAN.
    - Either JUCE_INTEL or JUCE_ARM
    - Either JUCE_GCC or JUCE_CLANG or JUCE_MSVC
*/

//==============================================================================
#ifdef JUCE_APP_CONFIG_HEADER
 #include JUCE_APP_CONFIG_HEADER
#elif ! defined (JUCE_GLOBAL_MODULE_SETTINGS_INCLUDED)
 /*
    Most projects will contain a global header file containing various settings that
    should be applied to all the code in your project. If you use the projucer, it'll
    set up a global header file for you automatically, but if you're doing things manually,
    you may want to set the JUCE_APP_CONFIG_HEADER macro with the name of a file to include,
    or just include one before all the module cpp files, in which you set
    JUCE_GLOBAL_MODULE_SETTINGS_INCLUDED=1 to silence this error.
    (Or if you don't need a global header, then you can just define JUCE_GLOBAL_MODULE_SETTINGS_INCLUDED
    globally to avoid this error).

    Note for people who hit this error when trying to compile a JUCE project created by
    a pre-v4.2 version of the Introjucer/Projucer, it's very easy to fix: just re-save
    your project with the latest version of the Projucer, and it'll magically fix this!
 */
 #error "No global header file was included!"
#endif

//==============================================================================
#if (defined (_WIN32) || defined (_WIN64))
  #define       JUCE_WIN32 1
  #define       JUCE_WINDOWS 1
#elif defined (JUCE_ANDROID)
  #undef        JUCE_ANDROID
  #define       JUCE_ANDROID 1
#elif defined (LINUX) || defined (__linux__)
  #define     JUCE_LINUX 1
#elif defined (__APPLE_CPP__) || defined(__APPLE_CC__)
  #include <CoreFoundation/CoreFoundation.h> // (needed to find out what platform we're using)
  #include "../native/juce_mac_ClangBugWorkaround.h"

  #if TARGET_OS_IPHONE || TARGET_IPHONE_SIMULATOR
    #define     JUCE_IPHONE 1
    #define     JUCE_IOS 1
  #else
    #define     JUCE_MAC 1
  #endif
#elif defined (__FreeBSD__)
  #define       JUCE_BSD 1
#else
  #error "Unknown platform!"
#endif

//==============================================================================
#if JUCE_WINDOWS
  #ifdef _MSC_VER
    #ifdef _WIN64
      #define JUCE_64BIT 1
    #else
      #define JUCE_32BIT 1
    #endif
  #endif

  #ifdef _DEBUG
    #define JUCE_DEBUG 1
  #endif

  #ifdef __MINGW32__
    #define JUCE_MINGW 1
    #ifdef __MINGW64__
      #define JUCE_64BIT 1
    #else
      #define JUCE_32BIT 1
    #endif
  #endif

  /** If defined, this indicates that the processor is little-endian. */
  #define JUCE_LITTLE_ENDIAN 1

  #define JUCE_INTEL 1
#endif

//==============================================================================
#if JUCE_MAC || JUCE_IOS

  #if defined (DEBUG) || defined (_DEBUG) || ! (defined (NDEBUG) || defined (_NDEBUG))
    #define JUCE_DEBUG 1
  #endif

  #if ! (defined (DEBUG) || defined (_DEBUG) || defined (NDEBUG) || defined (_NDEBUG))
    #warning "Neither NDEBUG or DEBUG has been defined - you should set one of these to make it clear whether this is a release build,"
  #endif

  #ifdef __LITTLE_ENDIAN__
    #define JUCE_LITTLE_ENDIAN 1
  #else
    #define JUCE_BIG_ENDIAN 1
  #endif

  #ifdef __LP64__
    #define JUCE_64BIT 1
  #else
    #define JUCE_32BIT 1
  #endif

  #if defined (__ppc__) || defined (__ppc64__)
    #error "PowerPC is no longer supported by JUCE!"
  #elif defined (__arm__) || defined (__arm64__)
    #define JUCE_ARM 1
  #else
    #define JUCE_INTEL 1
  #endif

  #if JUCE_MAC && MAC_OS_X_VERSION_MIN_REQUIRED < MAC_OS_X_VERSION_10_5
    #error "Building for OSX 10.4 is no longer supported!"
  #endif

  #if JUCE_MAC && ! defined (MAC_OS_X_VERSION_10_6)
    #error "To build with 10.5 compatibility, use a later SDK and set the deployment target to 10.5"
  #endif
#endif

//==============================================================================
#if JUCE_LINUX || JUCE_ANDROID

  #ifdef _DEBUG
    #define JUCE_DEBUG 1
  #endif

  // Allow override for big-endian Linux platforms
  #if defined (__LITTLE_ENDIAN__) || ! defined (JUCE_BIG_ENDIAN)
    #define JUCE_LITTLE_ENDIAN 1
    #undef JUCE_BIG_ENDIAN
  #else
    #undef JUCE_LITTLE_ENDIAN
    #define JUCE_BIG_ENDIAN 1
  #endif

  #if defined (__LP64__) || defined (_LP64) || defined (__arm64__)
    #define JUCE_64BIT 1
  #else
    #define JUCE_32BIT 1
  #endif

  #if defined (__arm__) || defined (__arm64__)
    #define JUCE_ARM 1
  #elif __MMX__ || __SSE__ || __amd64__
    #define JUCE_INTEL 1
  #endif
#endif

//==============================================================================
// Compiler type macros.

#ifdef __clang__
  #define JUCE_CLANG 1
#elif defined (__GNUC__)
  #define JUCE_GCC 1
#elif defined (_MSC_VER)
  #define JUCE_MSVC 1

  #if _MSC_VER < 1500
    #define JUCE_VC8_OR_EARLIER 1

    #if _MSC_VER < 1400
      #error "Visual Studio 2003 and earlier are no longer supported!"
    #endif
  #endif
#else
  #error unknown compiler
#endif

#endif   // JUCE_TARGETPLATFORM_H_INCLUDED
