/*
  ==============================================================================

   This file is part of the JUCE library.
   Copyright (c) 2015 - ROLI Ltd.

   Permission is granted to use this software under the terms of either:
   a) the GPL v2 (or any later version)
   b) the Affero GPL v3

   Details of these licenses can be found at: www.gnu.org/licenses

   JUCE is distributed in the hope that it will be useful, but WITHOUT ANY
   WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
   A PARTICULAR PURPOSE.  See the GNU General Public License for more details.

   ------------------------------------------------------------------------------

   To release a closed-source product which uses JUCE, commercial licenses are
   available: visit www.juce.com for more information.

  ==============================================================================
*/

#ifdef JUCE_EVENTS_H_INCLUDED
 /* When you add this cpp file to your project, you mustn't include it in a file where you've
    already included any other headers - just put it inside a file on its own, possibly with your config
    flags preceding it, but don't include anything else. That also includes avoiding any automatic prefix
    header files that the compiler may be using.
 */
 #error "Incorrect use of JUCE cpp file"
#endif

#define JUCE_CORE_INCLUDE_OBJC_HELPERS 1
#define JUCE_CORE_INCLUDE_JNI_HELPERS 1
#define JUCE_CORE_INCLUDE_NATIVE_HEADERS 1
#define JUCE_EVENTS_INCLUDE_WIN32_MESSAGE_WINDOW 1

#include "juce_events.h"

//==============================================================================
#if JUCE_MAC
 #import <IOKit/IOKitLib.h>
 #import <IOKit/IOCFPlugIn.h>
 #import <IOKit/hid/IOHIDLib.h>
 #import <IOKit/hid/IOHIDKeys.h>
 #import <IOKit/pwr_mgt/IOPMLib.h>

#elif JUCE_LINUX
 #include <X11/Xlib.h>
 #include <X11/Xresource.h>
 #include <X11/Xutil.h>
 #undef KeyPress
 #include <unistd.h>
#endif

//==============================================================================
namespace juce
{

#include "messages/juce_ApplicationBase.cpp"
#include "messages/juce_DeletedAtShutdown.cpp"
#include "messages/juce_MessageListener.cpp"
#include "messages/juce_MessageManager.cpp"
#include "broadcasters/juce_ActionBroadcaster.cpp"
#include "broadcasters/juce_AsyncUpdater.cpp"
#include "broadcasters/juce_ChangeBroadcaster.cpp"
#include "timers/juce_MultiTimer.cpp"
#include "timers/juce_Timer.cpp"
#include "interprocess/juce_InterprocessConnection.cpp"
#include "interprocess/juce_InterprocessConnectionServer.cpp"
#include "interprocess/juce_ConnectedChildProcess.cpp"

//==============================================================================
#if JUCE_MAC
 #include "native/juce_osx_MessageQueue.h"
 #include "native/juce_mac_MessageManager.mm"

#elif JUCE_IOS
 #include "native/juce_osx_MessageQueue.h"
 #include "native/juce_ios_MessageManager.mm"

#elif JUCE_WINDOWS
 #include "native/juce_win32_Messaging.cpp"

#elif JUCE_LINUX
 #include "native/juce_ScopedXLock.h"
 #include "native/juce_linux_Messaging.cpp"

#elif JUCE_ANDROID
 #include "native/juce_android_Messaging.cpp"

#endif

}
