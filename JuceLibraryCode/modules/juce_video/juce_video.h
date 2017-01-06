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


/*******************************************************************************
 The block below describes the properties of this module, and is read by
 the Projucer to automatically generate project code that uses it.
 For details about the syntax and how to create or use a module, see the
 JUCE Module Format.txt file.


 BEGIN_JUCE_MODULE_DECLARATION

  ID:               juce_video
  vendor:           juce
  version:          4.2.4
  name:             JUCE video playback and capture classes
  description:      Classes for playing video and capturing camera input.
  website:          http://www.juce.com/juce
  license:          GPL/Commercial

  dependencies:     juce_data_structures juce_cryptography
  OSXFrameworks:    QTKit QuickTime

 END_JUCE_MODULE_DECLARATION

*******************************************************************************/


#ifndef JUCE_VIDEO_H_INCLUDED
#define JUCE_VIDEO_H_INCLUDED

//==============================================================================
#include <juce_gui_extra/juce_gui_extra.h>

//==============================================================================
/** Config: JUCE_DIRECTSHOW
    Enables DirectShow media-streaming architecture (MS Windows only).
*/
#ifndef JUCE_DIRECTSHOW
 #define JUCE_DIRECTSHOW 0
#endif

/** Config: JUCE_MEDIAFOUNDATION
    Enables Media Foundation multimedia platform (Windows Vista and above).
*/
#ifndef JUCE_MEDIAFOUNDATION
 #define JUCE_MEDIAFOUNDATION 0
#endif

#if ! JUCE_WINDOWS
 #undef JUCE_DIRECTSHOW
 #undef JUCE_MEDIAFOUNDATION
#endif

/** Config: JUCE_QUICKTIME
    Enables the QuickTimeMovieComponent class (Mac and Windows).
    If you're building on Windows, you'll need to have the Apple QuickTime SDK
    installed, and its header files will need to be on your include path.
*/
#if ! (defined (JUCE_QUICKTIME) || JUCE_LINUX || JUCE_IOS || JUCE_ANDROID || (JUCE_WINDOWS && ! JUCE_MSVC))
 #define JUCE_QUICKTIME 0
#endif

/** Config: JUCE_USE_CAMERA
    Enables web-cam support using the CameraDevice class (Mac and Windows).
*/
#if (JUCE_QUICKTIME || JUCE_WINDOWS) && ! defined (JUCE_USE_CAMERA)
 #define JUCE_USE_CAMERA 0
#endif

#if ! (JUCE_MAC || JUCE_WINDOWS)
 #undef JUCE_QUICKTIME
 #undef JUCE_USE_CAMERA
#endif

//==============================================================================
namespace juce
{

#include "playback/juce_DirectShowComponent.h"
#include "playback/juce_QuickTimeMovieComponent.h"
#include "capture/juce_CameraDevice.h"

}

#endif   // JUCE_VIDEO_H_INCLUDED
