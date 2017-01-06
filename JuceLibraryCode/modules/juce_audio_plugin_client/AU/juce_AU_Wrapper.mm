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

#include "../../juce_core/system/juce_TargetPlatform.h"
#include "../utility/juce_CheckSettingMacros.h"

#if JucePlugin_Build_AU

#if __LP64__
 #undef JUCE_SUPPORT_CARBON
 #define JUCE_SUPPORT_CARBON 0
#endif

#ifdef __clang__
 #pragma clang diagnostic push
 #pragma clang diagnostic ignored "-Wshorten-64-to-32"
 #pragma clang diagnostic ignored "-Wunused-parameter"
 #pragma clang diagnostic ignored "-Wdeprecated-declarations"
 #pragma clang diagnostic ignored "-Wsign-conversion"
 #pragma clang diagnostic ignored "-Wconversion"
 #pragma clang diagnostic ignored "-Woverloaded-virtual"
#endif

#include "../utility/juce_IncludeSystemHeaders.h"

#include <AudioUnit/AUCocoaUIView.h>
#include <AudioUnit/AudioUnit.h>
#include <AudioToolbox/AudioUnitUtilities.h>
#include <CoreMIDI/MIDIServices.h>
#include "CoreAudioUtilityClasses/MusicDeviceBase.h"

/** The BUILD_AU_CARBON_UI flag lets you specify whether old-school carbon hosts are supported as
    well as ones that can open a cocoa view. If this is enabled, you'll need to also add the AUCarbonBase
    files to your project.
*/
#if ! (defined (BUILD_AU_CARBON_UI) || JUCE_64BIT)
 #define BUILD_AU_CARBON_UI 1
#endif

#ifdef __LP64__
 #undef BUILD_AU_CARBON_UI  // (not possible in a 64-bit build)
#endif

#if BUILD_AU_CARBON_UI
 #include "CoreAudioUtilityClasses/AUCarbonViewBase.h"
#endif

#ifdef __clang__
 #pragma clang diagnostic pop
#endif

#define JUCE_MAC_WINDOW_VISIBITY_BODGE 1
#define JUCE_CORE_INCLUDE_OBJC_HELPERS 1

#include "../utility/juce_IncludeModuleHeaders.h"
#include "../utility/juce_FakeMouseMoveGenerator.h"
#include "../utility/juce_CarbonVisibility.h"
#include "../utility/juce_PluginBusUtilities.h"

#include "juce_AU_Shared.h"

//==============================================================================
static Array<void*> activePlugins, activeUIs;

static const AudioUnitPropertyID juceFilterObjectPropertyID = 0x1a45ffe9;

// make sure the audio processor is initialized before the AUBase class
struct AudioProcessorHolder
{
    AudioProcessorHolder (bool initialiseGUI)
    {
        if (initialiseGUI)
        {
           #if BUILD_AU_CARBON_UI
            NSApplicationLoad();
           #endif

            initialiseJuce_GUI();
        }

        juceFilter = createPluginFilterOfType (AudioProcessor::wrapperType_AudioUnit);
    }

    ScopedPointer<AudioProcessor> juceFilter;
};

//==============================================================================
class JuceAU   : public AudioProcessorHolder,
                 public MusicDeviceBase,
                 public AudioProcessorListener,
                 public AudioPlayHead,
                 public ComponentListener
{
public:
    JuceAU (AudioUnit component)
        : AudioProcessorHolder(activePlugins.size() + activeUIs.size() == 0),
          MusicDeviceBase (component, (UInt32) PluginBusUtilities (*juceFilter, false).getNumEnabledBuses (true),
                                      (UInt32) PluginBusUtilities (*juceFilter, false).getNumEnabledBuses (false)),
          isBypassed (false),
          busUtils (*juceFilter, true, maxChannelsToProbeFor()),
          totalInChannels  (busUtils.findTotalNumChannels (true)),
          totalOutChannels (busUtils.findTotalNumChannels (false)),
          mapper (busUtils)
    {
        busUtils.init();

        channelInfo = AudioUnitHelpers::getAUChannelInfo (busUtils);

        juceFilter->setPlayHead (this);
        juceFilter->addListener (this);

        addParameters();

        activePlugins.add (this);

        zerostruct (auEvent);
        auEvent.mArgument.mParameter.mAudioUnit = GetComponentInstance();
        auEvent.mArgument.mParameter.mScope = kAudioUnitScope_Global;
        auEvent.mArgument.mParameter.mElement = 0;

        zerostruct (midiCallback);

        CreateElements();

        if (syncAudioUnitWithProcessor() != noErr)
            jassertfalse;
    }

    ~JuceAU()
    {
        deleteActiveEditors();
        juceFilter = nullptr;
        clearPresetsArray();

        jassert (activePlugins.contains (this));
        activePlugins.removeFirstMatchingValue (this);

        if (activePlugins.size() + activeUIs.size() == 0)
            shutdownJuce_GUI();
    }

    //==============================================================================
    ComponentResult Initialize() override
    {
        ComponentResult err;
        PluginBusUtilities::ScopedBusRestorer restorer (busUtils);

        if ((err = syncProcessorWithAudioUnit()) != noErr)
            return err;

        if ((err = MusicDeviceBase::Initialize()) != noErr)
            return err;

        mapper.alloc();

        prepareToPlay();
        restorer.release();

        return noErr;
    }

    void Cleanup() override
    {
        MusicDeviceBase::Cleanup();

        mapper.release();

        if (juceFilter != nullptr)
            juceFilter->releaseResources();

        audioBuffer.release();
        midiEvents.clear();
        incomingEvents.clear();
        prepared = false;
    }

    ComponentResult Reset (AudioUnitScope inScope, AudioUnitElement inElement) override
    {
        if (! prepared)
            prepareToPlay();

        if (juceFilter != nullptr)
            juceFilter->reset();

        return MusicDeviceBase::Reset (inScope, inElement);
    }

    //==============================================================================
    void prepareToPlay()
    {
        if (juceFilter != nullptr)
        {
            juceFilter->setRateAndBufferSizeDetails (getSampleRate(), (int) GetMaxFramesPerSlice());

            audioBuffer.prepare (totalInChannels, totalOutChannels, (int) GetMaxFramesPerSlice() + 32);
            juceFilter->prepareToPlay (getSampleRate(), (int) GetMaxFramesPerSlice());

            midiEvents.ensureSize (2048);
            midiEvents.clear();
            incomingEvents.ensureSize (2048);
            incomingEvents.clear();

            prepared = true;
        }
    }

    //==============================================================================
    static OSStatus ComponentEntryDispatch (ComponentParameters* params, JuceAU* effect)
    {
        if (effect == nullptr)
            return paramErr;

        switch (params->what)
        {
            case kMusicDeviceMIDIEventSelect:
            case kMusicDeviceSysExSelect:
                return AUMIDIBase::ComponentEntryDispatch (params, effect);
            default:
                break;
        }

        return MusicDeviceBase::ComponentEntryDispatch (params, effect);
    }

    //==============================================================================
    bool BusCountWritable (AudioUnitScope scope) override
    {
        bool isInput;

        if (scopeToDirection (scope, isInput) != noErr)
            return false;

       #if JucePlugin_IsMidiEffect
        return false;
       #elif JucePlugin_IsSynth
        if (isInput) return busUtils.hasDynamicInBuses();
       #endif

        return isInput ? (busUtils.getBusCount (true)  > 1 && busUtils.hasDynamicInBuses())
                       : (busUtils.getBusCount (false) > 1 && busUtils.hasDynamicOutBuses());
    }

    OSStatus SetBusCount (AudioUnitScope scope, UInt32 count) override
    {
        OSStatus err = noErr;
        bool isInput;

        if ((err = scopeToDirection (scope, isInput)) != noErr)
            return err;

        if (count != GetScope (scope).GetNumberOfElements())
        {
            if ((isInput && (! busUtils.hasDynamicInBuses())) || ((! isInput) && (! busUtils.hasDynamicOutBuses())))
                return kAudioUnitErr_PropertyNotWritable;

            // Similar as with the stream format, we don't really tell the AudioProcessor about
            // the bus count change until Initialize is called. We only generally test if
            // this bus count can work.
            if (static_cast<int> (count) > busUtils.getBusCount (isInput))
                return kAudioUnitErr_FormatNotSupported;

            // we need to already create the underlying elements so that we can change their formats
            if ((err = MusicDeviceBase::SetBusCount (scope, count)) != noErr)
                return err;

            // however we do need to update the format tag: we need to do the same thing in SetFormat, for example
            const int currentNumBus = busUtils.getNumEnabledBuses (isInput);
            const int requestedNumBus = static_cast<int> (count);

            if (currentNumBus < requestedNumBus)
            {
                for (int busNr = currentNumBus; busNr < requestedNumBus; ++busNr)
                    if ((err = syncAudioUnitWithChannelSet (isInput, busNr, busUtils.getDefaultLayoutForBus (isInput, busNr))) != noErr)
                        break;
            }
            else
            {
                AudioChannelLayoutTag nulltag = AudioUnitHelpers::ChannelSetToCALayoutTag (AudioChannelSet());

                for (int busNr = requestedNumBus; busNr < currentNumBus; ++busNr)
                    getCurrentLayout (isInput, busNr) = nulltag;
            }

            // update total channel count
            totalInChannels = busUtils.findTotalNumChannels (true);
            totalOutChannels = busUtils.findTotalNumChannels (false);

            if (err != noErr)
                return err;
        }

        return MusicDeviceBase::SetBusCount (scope, count);
    }

    UInt32 SupportedNumChannels (const AUChannelInfo** outInfo) override
    {
        if (outInfo != nullptr)
            *outInfo = channelInfo.getRawDataPointer();

        return (UInt32) channelInfo.size();
    }

    //==============================================================================
    ComponentResult GetPropertyInfo (AudioUnitPropertyID inID,
                                     AudioUnitScope inScope,
                                     AudioUnitElement inElement,
                                     UInt32& outDataSize,
                                     Boolean& outWritable) override
    {
        if (inScope == kAudioUnitScope_Global)
        {
            switch (inID)
            {
                case juceFilterObjectPropertyID:
                    outWritable = false;
                    outDataSize = sizeof (void*) * 2;
                    return noErr;

                case kAudioUnitProperty_OfflineRender:
                    outWritable = true;
                    outDataSize = sizeof (UInt32);
                    return noErr;

                case kMusicDeviceProperty_InstrumentCount:
                    outDataSize = sizeof (UInt32);
                    outWritable = false;
                    return noErr;

                case kAudioUnitProperty_CocoaUI:
                    outDataSize = sizeof (AudioUnitCocoaViewInfo);
                    outWritable = true;
                    return noErr;

               #if JucePlugin_ProducesMidiOutput || JucePlugin_IsMidiEffect
                case kAudioUnitProperty_MIDIOutputCallbackInfo:
                    outDataSize = sizeof (CFArrayRef);
                    outWritable = false;
                    return noErr;

                case kAudioUnitProperty_MIDIOutputCallback:
                    outDataSize = sizeof (AUMIDIOutputCallbackStruct);
                    outWritable = true;
                    return noErr;
               #endif

                case kAudioUnitProperty_ParameterStringFromValue:
                     outDataSize = sizeof (AudioUnitParameterStringFromValue);
                     outWritable = false;
                     return noErr;

                case kAudioUnitProperty_ParameterValueFromString:
                     outDataSize = sizeof (AudioUnitParameterValueFromString);
                     outWritable = false;
                     return noErr;

                case kAudioUnitProperty_BypassEffect:
                    outDataSize = sizeof (UInt32);
                    outWritable = true;
                    return noErr;

                case kAudioUnitProperty_SupportsMPE:
                    outDataSize = sizeof (UInt32);
                    outWritable = false;
                    return noErr;

                default: break;
            }
        }

        return MusicDeviceBase::GetPropertyInfo (inID, inScope, inElement, outDataSize, outWritable);
    }

    ComponentResult GetProperty (AudioUnitPropertyID inID,
                                 AudioUnitScope inScope,
                                 AudioUnitElement inElement,
                                 void* outData) override
    {
        if (inScope == kAudioUnitScope_Global)
        {
            switch (inID)
            {
                case juceFilterObjectPropertyID:
                    ((void**) outData)[0] = (void*) static_cast<AudioProcessor*> (juceFilter);
                    ((void**) outData)[1] = (void*) this;
                    return noErr;

                case kAudioUnitProperty_OfflineRender:
                    *(UInt32*) outData = (juceFilter != nullptr && juceFilter->isNonRealtime()) ? 1 : 0;
                    return noErr;

                case kMusicDeviceProperty_InstrumentCount:
                    *(UInt32*) outData = 1;
                    return noErr;

                case kAudioUnitProperty_BypassEffect:
                    *(UInt32*) outData = isBypassed ? 1 : 0;
                    return noErr;

                case kAudioUnitProperty_SupportsMPE:
                    *(UInt32*) outData = (juceFilter != nullptr && juceFilter->supportsMPE()) ? 1 : 0;
                    return noErr;

                case kAudioUnitProperty_CocoaUI:
                    {
                        JUCE_AUTORELEASEPOOL
                        {
                            static JuceUICreationClass cls;

                            // (NB: this may be the host's bundle, not necessarily the component's)
                            NSBundle* bundle = [NSBundle bundleForClass: cls.cls];

                            AudioUnitCocoaViewInfo* info = static_cast<AudioUnitCocoaViewInfo*> (outData);
                            info->mCocoaAUViewClass[0] = (CFStringRef) [juceStringToNS (class_getName (cls.cls)) retain];
                            info->mCocoaAUViewBundleLocation = (CFURLRef) [[NSURL fileURLWithPath: [bundle bundlePath]] retain];
                        }

                        return noErr;
                    }

                    break;

               #if JucePlugin_ProducesMidiOutput || JucePlugin_IsMidiEffect
                case kAudioUnitProperty_MIDIOutputCallbackInfo:
                {
                    CFStringRef strs[1];
                    strs[0] = CFSTR ("MIDI Callback");

                    CFArrayRef callbackArray = CFArrayCreate (nullptr, (const void**) strs, 1, &kCFTypeArrayCallBacks);
                    *(CFArrayRef*) outData = callbackArray;
                    return noErr;
                }
               #endif

                case kAudioUnitProperty_ParameterValueFromString:
                {
                    if (AudioUnitParameterValueFromString* pv = (AudioUnitParameterValueFromString*) outData)
                    {
                        if (juceFilter != nullptr)
                        {
                            const int paramID = getJuceIndexForAUParameterID (pv->inParamID);
                            const String text (String::fromCFString (pv->inString));

                            if (AudioProcessorParameter* param = juceFilter->getParameters() [paramID])
                                pv->outValue = param->getValueForText (text);
                            else
                                pv->outValue = text.getFloatValue();

                            return noErr;
                        }
                    }
                }
                break;

                case kAudioUnitProperty_ParameterStringFromValue:
                {
                    if (AudioUnitParameterStringFromValue* pv = (AudioUnitParameterStringFromValue*) outData)
                    {
                        if (juceFilter != nullptr)
                        {
                            const int paramID = getJuceIndexForAUParameterID (pv->inParamID);
                            const float value = (float) *(pv->inValue);
                            String text;

                            if (AudioProcessorParameter* param = juceFilter->getParameters() [paramID])
                                text = param->getText (value, 0);
                            else
                                text = String (value);

                            pv->outString = text.toCFString();
                            return noErr;
                        }
                    }
                }
                break;

                default:
                    break;
            }
        }

        return MusicDeviceBase::GetProperty (inID, inScope, inElement, outData);
    }

    ComponentResult SetProperty (AudioUnitPropertyID inID,
                                 AudioUnitScope inScope,
                                 AudioUnitElement inElement,
                                 const void* inData,
                                 UInt32 inDataSize) override
    {
        if (inScope == kAudioUnitScope_Global)
        {
            switch (inID)
            {
               #if JucePlugin_ProducesMidiOutput || JucePlugin_IsMidiEffect
                case kAudioUnitProperty_MIDIOutputCallback:
                    if (inDataSize < sizeof (AUMIDIOutputCallbackStruct))
                        return kAudioUnitErr_InvalidPropertyValue;

                    if (AUMIDIOutputCallbackStruct* callbackStruct = (AUMIDIOutputCallbackStruct*) inData)
                        midiCallback = *callbackStruct;

                    return noErr;
               #endif

                case kAudioUnitProperty_BypassEffect:
                {
                    if (inDataSize < sizeof (UInt32))
                        return kAudioUnitErr_InvalidPropertyValue;

                    const bool newBypass = *((UInt32*) inData) != 0;

                    if (newBypass != isBypassed)
                    {
                        isBypassed = newBypass;

                        if (! isBypassed && IsInitialized()) // turning bypass off and we're initialized
                            Reset (0, 0);
                    }

                    return noErr;
                }

                case kAudioUnitProperty_OfflineRender:
                    if (juceFilter != nullptr)
                        juceFilter->setNonRealtime ((*(UInt32*) inData) != 0);

                    return noErr;

                default: break;
            }
        }

        return MusicDeviceBase::SetProperty (inID, inScope, inElement, inData, inDataSize);
    }

    //==============================================================================
    ComponentResult SaveState (CFPropertyListRef* outData) override
    {
        ComponentResult err = MusicDeviceBase::SaveState (outData);

        if (err != noErr)
            return err;

        jassert (CFGetTypeID (*outData) == CFDictionaryGetTypeID());

        CFMutableDictionaryRef dict = (CFMutableDictionaryRef) *outData;

        if (juceFilter != nullptr)
        {
            juce::MemoryBlock state;
            juceFilter->getCurrentProgramStateInformation (state);

            if (state.getSize() > 0)
            {
                CFDataRef ourState = CFDataCreate (kCFAllocatorDefault, (const UInt8*) state.getData(), (CFIndex) state.getSize());

                CFStringRef key = CFStringCreateWithCString (kCFAllocatorDefault, JUCE_STATE_DICTIONARY_KEY, kCFStringEncodingUTF8);
                CFDictionarySetValue (dict, key, ourState);
                CFRelease (key);
                CFRelease (ourState);
            }
        }

        return noErr;
    }

    ComponentResult RestoreState (CFPropertyListRef inData) override
    {
        {
            // Remove the data entry from the state to prevent the superclass loading the parameters
            CFMutableDictionaryRef copyWithoutData = CFDictionaryCreateMutableCopy (nullptr, 0, (CFDictionaryRef) inData);
            CFDictionaryRemoveValue (copyWithoutData, CFSTR (kAUPresetDataKey));
            ComponentResult err = MusicDeviceBase::RestoreState (copyWithoutData);
            CFRelease (copyWithoutData);

            if (err != noErr)
                return err;
        }

        if (juceFilter != nullptr)
        {
            CFDictionaryRef dict = (CFDictionaryRef) inData;
            CFDataRef data = 0;

            CFStringRef key = CFStringCreateWithCString (kCFAllocatorDefault, JUCE_STATE_DICTIONARY_KEY, kCFStringEncodingUTF8);

            bool valuePresent = CFDictionaryGetValueIfPresent (dict, key, (const void**) &data);
            CFRelease (key);

            if (valuePresent)
            {
                if (data != 0)
                {
                    const int numBytes = (int) CFDataGetLength (data);
                    const juce::uint8* const rawBytes = CFDataGetBytePtr (data);

                    if (numBytes > 0)
                        juceFilter->setCurrentProgramStateInformation (rawBytes, numBytes);
                }
            }
        }

        return noErr;
    }

    //==============================================================================
    UInt32 GetAudioChannelLayout (AudioUnitScope scope, AudioUnitElement element,
                                  AudioChannelLayout* outLayoutPtr, Boolean& outWritable) override
    {
        bool isInput;
        int busNr;

        outWritable = false;

        if (elementToBusIdx (scope, element, isInput, busNr) != noErr)
            return 0;

        if (busUtils.busIgnoresLayout(isInput, busNr))
            return 0;

        outWritable = true;

        const size_t sizeInBytes = sizeof (AudioChannelLayout) - sizeof (AudioChannelDescription);

        if (outLayoutPtr != nullptr)
        {
            zeromem (outLayoutPtr, sizeInBytes);
            outLayoutPtr->mChannelLayoutTag = getCurrentLayout (isInput, busNr);
        }

        return sizeInBytes;
    }

    UInt32 GetChannelLayoutTags (AudioUnitScope scope, AudioUnitElement element, AudioChannelLayoutTag* outLayoutTags) override
    {
        bool isInput;
        int busNr;

        if (elementToBusIdx (scope, element, isInput, busNr) != noErr)
            return 0;

        if (busUtils.busIgnoresLayout(isInput, busNr))
            return 0;

        const Array<AudioChannelLayoutTag>& layouts = getSupportedBusLayouts (isInput, busNr);

        if (outLayoutTags != nullptr)
            std::copy (layouts.begin(), layouts.end(), outLayoutTags);

        return (UInt32) layouts.size();
    }

    OSStatus SetAudioChannelLayout(AudioUnitScope scope, AudioUnitElement element, const AudioChannelLayout* inLayout) override
    {
        bool isInput;
        int busNr;
        OSStatus err;

        if ((err = elementToBusIdx (scope, element, isInput, busNr)) != noErr)
            return err;

        if (busUtils.busIgnoresLayout(isInput, busNr))
            return kAudioUnitErr_PropertyNotWritable;

        if (IsInitialized())
            jassertfalse; // TODO: Fabian arrggghhhh: auval changes layout after it is initialized

        if (inLayout == nullptr)
            return kAudioUnitErr_InvalidPropertyValue;

        if (const AUIOElement* ioElement = GetIOElement (isInput ? kAudioUnitScope_Input :  kAudioUnitScope_Output, element))
        {
            const AudioChannelSet newChannelSet = AudioUnitHelpers::CoreAudioChannelLayoutToJuceType (*inLayout);
            const int currentNumChannels = static_cast<int> (ioElement->GetStreamFormat().NumberChannels());

            if (currentNumChannels != newChannelSet.size())
                return kAudioUnitErr_InvalidPropertyValue;

            // check if the new layout could be potentially set
            PluginBusUtilities::ScopedBusRestorer restorer (busUtils);

            bool success = juceFilter->setPreferredBusArrangement (isInput, busNr, newChannelSet);

            if (!success)
                return kAudioUnitErr_FormatNotSupported;

            getCurrentLayout (isInput, busNr) = AudioUnitHelpers::ChannelSetToCALayoutTag (newChannelSet);

            return noErr;
        }
        else
            jassertfalse;

        return kAudioUnitErr_InvalidElement;
    }

    //==============================================================================
    ComponentResult GetParameterInfo (AudioUnitScope inScope,
                                      AudioUnitParameterID inParameterID,
                                      AudioUnitParameterInfo& outParameterInfo) override
    {
        const int index = getJuceIndexForAUParameterID (inParameterID);

        if (inScope == kAudioUnitScope_Global
             && juceFilter != nullptr
             && index < juceFilter->getNumParameters())
        {
            outParameterInfo.flags = (UInt32) (kAudioUnitParameterFlag_IsWritable
                                                | kAudioUnitParameterFlag_IsReadable
                                                | kAudioUnitParameterFlag_HasCFNameString
                                                | kAudioUnitParameterFlag_ValuesHaveStrings);

           #if JucePlugin_AUHighResolutionParameters
            outParameterInfo.flags |= (UInt32) kAudioUnitParameterFlag_IsHighResolution;
           #endif

            const String name (juceFilter->getParameterName (index));

            // set whether the param is automatable (unnamed parameters aren't allowed to be automated)
            if (name.isEmpty() || ! juceFilter->isParameterAutomatable (index))
                outParameterInfo.flags |= kAudioUnitParameterFlag_NonRealTime;

            if (juceFilter->isMetaParameter (index))
                outParameterInfo.flags |= kAudioUnitParameterFlag_IsGlobalMeta;

            MusicDeviceBase::FillInParameterName (outParameterInfo, name.toCFString(), true);

            outParameterInfo.minValue = 0.0f;
            outParameterInfo.maxValue = 1.0f;
            outParameterInfo.defaultValue = juceFilter->getParameterDefaultValue (index);
            jassert (outParameterInfo.defaultValue >= outParameterInfo.minValue
                      && outParameterInfo.defaultValue <= outParameterInfo.maxValue);
            outParameterInfo.unit = kAudioUnitParameterUnit_Generic;

            return noErr;
        }

        return kAudioUnitErr_InvalidParameter;
    }

    ComponentResult GetParameter (AudioUnitParameterID inID,
                                  AudioUnitScope inScope,
                                  AudioUnitElement inElement,
                                  Float32& outValue) override
    {
        if (inScope == kAudioUnitScope_Global && juceFilter != nullptr)
        {
            const int index = getJuceIndexForAUParameterID (inID);

            outValue = juceFilter->getParameter (index);
            return noErr;
        }

        return MusicDeviceBase::GetParameter (inID, inScope, inElement, outValue);
    }

    ComponentResult SetParameter (AudioUnitParameterID inID,
                                  AudioUnitScope inScope,
                                  AudioUnitElement inElement,
                                  Float32 inValue,
                                  UInt32 inBufferOffsetInFrames) override
    {
        if (inScope == kAudioUnitScope_Global && juceFilter != nullptr)
        {
            const int index = getJuceIndexForAUParameterID (inID);

            juceFilter->setParameter (index, inValue);
            return noErr;
        }

        return MusicDeviceBase::SetParameter (inID, inScope, inElement, inValue, inBufferOffsetInFrames);
    }

    // No idea what this method actually does or what it should return. Current Apple docs say nothing about it.
    // (Note that this isn't marked 'override' in case older versions of the SDK don't include it)
    bool CanScheduleParameters() const override          { return false; }

    //==============================================================================
    ComponentResult Version() override                   { return JucePlugin_VersionCode; }
    bool SupportsTail() override                         { return true; }
    Float64 GetTailTime() override                       { return juceFilter->getTailLengthSeconds(); }
    double getSampleRate()                               { return busUtils.getNumEnabledBuses (false) > 0 ? GetOutput(0)->GetStreamFormat().mSampleRate : 44100.0; }

    Float64 GetLatency() override
    {
        const double rate = getSampleRate();
        jassert (rate > 0);
        return rate > 0 ? juceFilter->getLatencySamples() / rate : 0;
    }

    //==============================================================================
   #if BUILD_AU_CARBON_UI
    int GetNumCustomUIComponents() override
    {
        return getHostType().isDigitalPerformer() ? 0 : 1;
    }

    void GetUIComponentDescs (ComponentDescription* inDescArray) override
    {
        inDescArray[0].componentType = kAudioUnitCarbonViewComponentType;
        inDescArray[0].componentSubType = JucePlugin_AUSubType;
        inDescArray[0].componentManufacturer = JucePlugin_AUManufacturerCode;
        inDescArray[0].componentFlags = 0;
        inDescArray[0].componentFlagsMask = 0;
    }
   #endif

    //==============================================================================
    bool getCurrentPosition (AudioPlayHead::CurrentPositionInfo& info) override
    {
        info.timeSigNumerator = 0;
        info.timeSigDenominator = 0;
        info.editOriginTime = 0;
        info.ppqPositionOfLastBarStart = 0;
        info.isRecording = false;

        switch (lastTimeStamp.mSMPTETime.mType)
        {
            case kSMPTETimeType24:          info.frameRate = AudioPlayHead::fps24; break;
            case kSMPTETimeType25:          info.frameRate = AudioPlayHead::fps25; break;
            case kSMPTETimeType30Drop:      info.frameRate = AudioPlayHead::fps30drop; break;
            case kSMPTETimeType30:          info.frameRate = AudioPlayHead::fps30; break;
            case kSMPTETimeType2997:        info.frameRate = AudioPlayHead::fps2997; break;
            case kSMPTETimeType2997Drop:    info.frameRate = AudioPlayHead::fps2997drop; break;
            default:                        info.frameRate = AudioPlayHead::fpsUnknown; break;
        }

        if (CallHostBeatAndTempo (&info.ppqPosition, &info.bpm) != noErr)
        {
            info.ppqPosition = 0;
            info.bpm = 0;
        }

        UInt32 outDeltaSampleOffsetToNextBeat;
        double outCurrentMeasureDownBeat;
        float num;
        UInt32 den;

        if (CallHostMusicalTimeLocation (&outDeltaSampleOffsetToNextBeat, &num, &den,
                                         &outCurrentMeasureDownBeat) == noErr)
        {
            info.timeSigNumerator   = (int) num;
            info.timeSigDenominator = (int) den;
            info.ppqPositionOfLastBarStart = outCurrentMeasureDownBeat;
        }

        double outCurrentSampleInTimeLine, outCycleStartBeat = 0, outCycleEndBeat = 0;
        Boolean playing = false, looping = false, playchanged;

        if (CallHostTransportState (&playing,
                                    &playchanged,
                                    &outCurrentSampleInTimeLine,
                                    &looping,
                                    &outCycleStartBeat,
                                    &outCycleEndBeat) != noErr)
        {
            // If the host doesn't support this callback, then use the sample time from lastTimeStamp:
            outCurrentSampleInTimeLine = lastTimeStamp.mSampleTime;
        }

        info.isPlaying = playing;
        info.timeInSamples = (int64) (outCurrentSampleInTimeLine + 0.5);
        info.timeInSeconds = info.timeInSamples / getSampleRate();
        info.isLooping = looping;
        info.ppqLoopStart = outCycleStartBeat;
        info.ppqLoopEnd = outCycleEndBeat;

        return true;
    }

    void sendAUEvent (const AudioUnitEventType type, const int juceParamIndex)
    {
        auEvent.mEventType = type;
        auEvent.mArgument.mParameter.mParameterID = getAUParameterIDForIndex (juceParamIndex);
        AUEventListenerNotify (0, 0, &auEvent);
    }

    void audioProcessorParameterChanged (AudioProcessor*, int index, float /*newValue*/) override
    {
        sendAUEvent (kAudioUnitEvent_ParameterValueChange, index);
    }

    void audioProcessorParameterChangeGestureBegin (AudioProcessor*, int index) override
    {
        sendAUEvent (kAudioUnitEvent_BeginParameterChangeGesture, index);
    }

    void audioProcessorParameterChangeGestureEnd (AudioProcessor*, int index) override
    {
        sendAUEvent (kAudioUnitEvent_EndParameterChangeGesture, index);
    }

    void audioProcessorChanged (AudioProcessor*) override
    {
        PropertyChanged (kAudioUnitProperty_Latency,       kAudioUnitScope_Global, 0);
        PropertyChanged (kAudioUnitProperty_ParameterList, kAudioUnitScope_Global, 0);
        PropertyChanged (kAudioUnitProperty_ParameterInfo, kAudioUnitScope_Global, 0);

        refreshCurrentPreset();

        PropertyChanged (kAudioUnitProperty_PresentPreset, kAudioUnitScope_Global, 0);
    }

    //==============================================================================
    bool StreamFormatWritable (AudioUnitScope scope, AudioUnitElement element) override
    {
        bool ignore;
        int busIdx;

        return ((! IsInitialized()) && (elementToBusIdx (scope, element, ignore, busIdx) == noErr));
    }

    bool ValidFormat (AudioUnitScope scope, AudioUnitElement element, const CAStreamBasicDescription& format) override
    {
        bool isInput;
        int busNr;

        if (elementToBusIdx (scope, element, isInput, busNr) != noErr)
            return false;

        const int newNumChannels = static_cast<int> (format.NumberChannels());
        const int oldNumChannels = busUtils.getNumChannels (isInput, busNr);

        if (newNumChannels == oldNumChannels)
            return true;

        PluginBusUtilities::ScopedBusRestorer restorer (busUtils);

        return juceFilter->setPreferredBusArrangement (isInput, busNr, busUtils.getDefaultLayoutForChannelNumAndBus (isInput, busNr, newNumChannels))
                && MusicDeviceBase::ValidFormat (scope, element, format);
    }

    // AU requires us to override this for the sole reason that we need to find a default layout tag if the number of channels have changed
    OSStatus ChangeStreamFormat (AudioUnitScope scope, AudioUnitElement element, const CAStreamBasicDescription& old, const CAStreamBasicDescription& format) override
    {
        bool isInput;
        int busNr;
        OSStatus err = elementToBusIdx (scope, element, isInput, busNr);

        if (err != noErr)
            return err;

        AudioChannelLayoutTag& currentTag = getCurrentLayout (isInput, busNr);

        const int newNumChannels = static_cast<int> (format.NumberChannels());
        const int oldNumChannels = busUtils.getNumChannels (isInput, busNr);

        // predict channel layout
        AudioChannelSet set = (newNumChannels != oldNumChannels) ? busUtils.getDefaultLayoutForChannelNumAndBus (isInput, busNr, newNumChannels)
                                                                 : busUtils.getChannelSet (isInput, busNr);

        if (set == AudioChannelSet())
            return kAudioUnitErr_FormatNotSupported;

        err = MusicDeviceBase::ChangeStreamFormat (scope, element, old, format);

        if (err == noErr)
            currentTag = AudioUnitHelpers::ChannelSetToCALayoutTag (set);

        return err;
    }

    //==============================================================================
    ComponentResult Render (AudioUnitRenderActionFlags& ioActionFlags,
                            const AudioTimeStamp& inTimeStamp,
                            const UInt32 nFrames) override
    {
        lastTimeStamp = inTimeStamp;

        // prepare buffers
        {
            if (! pullInputAudio (ioActionFlags, inTimeStamp, nFrames))
                return noErr;

            prepareOutputBuffers (nFrames);
            audioBuffer.reset();
        }

        const int numInputBuses  = static_cast<int> (GetScope (kAudioUnitScope_Input) .GetNumberOfElements());
        const int numOutputBuses = static_cast<int> (GetScope (kAudioUnitScope_Output).GetNumberOfElements());

        // set buffer pointers to minimize copying
        {
            int chIdx = 0, numChannels;
            bool interleaved;
            AudioBufferList* buffer;

            // use output pointers
            for (int busIdx = 0; busIdx < numOutputBuses; ++busIdx)
            {
                if (! GetAudioBufferList (false, busIdx, buffer, interleaved, numChannels))
                    continue;

                const int* outLayoutMap = mapper.get (false, busIdx);

                for (int ch = 0; ch < numChannels; ++ch)
                    audioBuffer.setBuffer (chIdx++, interleaved ? nullptr : static_cast<float*> (buffer->mBuffers[outLayoutMap[ch]].mData));
            }

            // use input pointers on remaining channels
            int channelCount = 0;
            for (int busIdx = 0; chIdx < totalInChannels;)
            {
                busIdx = busUtils.getBusIdxForChannelIdx (true, chIdx, channelCount, busIdx);

                if (! GetAudioBufferList (true, busIdx, buffer, interleaved, numChannels))
                    continue;

                const int* inLayoutMap = mapper.get (true, busIdx);

                for (int ch = chIdx - channelCount; ch < numChannels; ++ch)
                    audioBuffer.setBuffer (chIdx++, interleaved ? nullptr : static_cast<float*> (buffer->mBuffers[inLayoutMap[ch]].mData));
            }
        }

        // copy input
        {
            for (int busIdx = 0; busIdx < numInputBuses; ++busIdx)
                audioBuffer.push (GetInput ((UInt32) busIdx)->GetBufferList(), mapper.get (true, busIdx));

            // clear remaining channels
            for (int i = totalInChannels; i < totalOutChannels; ++i)
                zeromem (audioBuffer.push(), sizeof (float) * nFrames);
        }

        // swap midi buffers
        {
            const ScopedLock sl (incomingMidiLock);
            midiEvents.clear();
            incomingEvents.swapWith (midiEvents);
        }

        // process audio
        processBlock (audioBuffer.getBuffer (nFrames), midiEvents);

        // copy back
        {
            for (int busIdx = 0; busIdx < numOutputBuses; ++busIdx)
                audioBuffer.pop (GetOutput ((UInt32) busIdx)->GetBufferList(), mapper.get (false, busIdx));
        }

        // process midi output
      #if JucePlugin_ProducesMidiOutput || JucePlugin_IsMidiEffect
        if (! midiEvents.isEmpty() && midiCallback.midiOutputCallback != nullptr)
            pushMidiOutput (nFrames);
      #endif

        midiEvents.clear();

        return noErr;
    }

    //==============================================================================
    ComponentResult StartNote (MusicDeviceInstrumentID, MusicDeviceGroupID, NoteInstanceID*, UInt32, const MusicDeviceNoteParams&) override { return noErr; }
    ComponentResult StopNote (MusicDeviceGroupID, NoteInstanceID, UInt32) override   { return noErr; }

    //==============================================================================
    OSStatus HandleMidiEvent (UInt8 nStatus, UInt8 inChannel, UInt8 inData1, UInt8 inData2, UInt32 inStartFrame) override
    {
       #if JucePlugin_WantsMidiInput || JucePlugin_IsMidiEffect
        const juce::uint8 data[] = { (juce::uint8) (nStatus | inChannel),
                                     (juce::uint8) inData1,
                                     (juce::uint8) inData2 };

        const ScopedLock sl (incomingMidiLock);
        incomingEvents.addEvent (data, 3, (int) inStartFrame);
        return noErr;
       #else
        ignoreUnused (nStatus, inChannel, inData1);
        ignoreUnused (inData2, inStartFrame);
        return kAudioUnitErr_PropertyNotInUse;
       #endif
    }

    OSStatus HandleSysEx (const UInt8* inData, UInt32 inLength) override
    {
       #if JucePlugin_WantsMidiInput || JucePlugin_IsMidiEffect
        const ScopedLock sl (incomingMidiLock);
        incomingEvents.addEvent (inData, (int) inLength, 0);
        return noErr;
       #else
        ignoreUnused (inData, inLength);
        return kAudioUnitErr_PropertyNotInUse;
       #endif
    }

    //==============================================================================
    ComponentResult GetPresets (CFArrayRef* outData) const override
    {
        if (outData != nullptr)
        {
            const int numPrograms = juceFilter->getNumPrograms();

            clearPresetsArray();
            presetsArray.insertMultiple (0, AUPreset(), numPrograms);

            CFMutableArrayRef presetsArrayRef = CFArrayCreateMutable (0, numPrograms, 0);

            for (int i = 0; i < numPrograms; ++i)
            {
                String name (juceFilter->getProgramName(i));
                if (name.isEmpty())
                    name = "Untitled";

                AUPreset& p = presetsArray.getReference(i);
                p.presetNumber = i;
                p.presetName = name.toCFString();

                CFArrayAppendValue (presetsArrayRef, &p);
            }

            *outData = (CFArrayRef) presetsArrayRef;
        }

        return noErr;
    }

    OSStatus NewFactoryPresetSet (const AUPreset& inNewFactoryPreset) override
    {
        const int numPrograms = juceFilter->getNumPrograms();
        const SInt32 chosenPresetNumber = (int) inNewFactoryPreset.presetNumber;

        if (chosenPresetNumber >= numPrograms)
            return kAudioUnitErr_InvalidProperty;

        AUPreset chosenPreset;
        chosenPreset.presetNumber = chosenPresetNumber;
        chosenPreset.presetName = juceFilter->getProgramName (chosenPresetNumber).toCFString();

        juceFilter->setCurrentProgram (chosenPresetNumber);
        SetAFactoryPresetAsCurrent (chosenPreset);

        return noErr;
    }

    void componentMovedOrResized (Component& component, bool /*wasMoved*/, bool /*wasResized*/) override
    {
        NSView* view = (NSView*) component.getWindowHandle();
        NSRect r = [[view superview] frame];
        r.origin.y = r.origin.y + r.size.height - component.getHeight();
        r.size.width = component.getWidth();
        r.size.height = component.getHeight();
        [[view superview] setFrame: r];
        [view setFrame: makeNSRect (component.getLocalBounds())];
        [view setNeedsDisplay: YES];
    }

    //==============================================================================
    class EditorCompHolder  : public Component
    {
    public:
        EditorCompHolder (AudioProcessorEditor* const editor)
        {
            setSize (editor->getWidth(), editor->getHeight());
            addAndMakeVisible (editor);

           #if ! JucePlugin_EditorRequiresKeyboardFocus
            setWantsKeyboardFocus (false);
           #else
            setWantsKeyboardFocus (true);
           #endif

            ignoreUnused (fakeMouseGenerator);
        }

        ~EditorCompHolder()
        {
            deleteAllChildren(); // note that we can't use a ScopedPointer because the editor may
                                 // have been transferred to another parent which takes over ownership.
        }

        static NSView* createViewFor (AudioProcessor* filter, JuceAU* au, AudioProcessorEditor* const editor)
        {
            EditorCompHolder* editorCompHolder = new EditorCompHolder (editor);
            NSRect r = makeNSRect (editorCompHolder->getLocalBounds());

            static JuceUIViewClass cls;
            NSView* view = [[cls.createInstance() initWithFrame: r] autorelease];

            JuceUIViewClass::setFilter (view, filter);
            JuceUIViewClass::setAU (view, au);
            JuceUIViewClass::setEditor (view, editorCompHolder);

            [view setHidden: NO];
            [view setPostsFrameChangedNotifications: YES];

            [[NSNotificationCenter defaultCenter] addObserver: view
                                                     selector: @selector (applicationWillTerminate:)
                                                         name: NSApplicationWillTerminateNotification
                                                       object: nil];
            activeUIs.add (view);

            editorCompHolder->addToDesktop (0, (void*) view);
            editorCompHolder->setVisible (view);
            return view;
        }

        void childBoundsChanged (Component*) override
        {
            if (Component* editor = getChildComponent(0))
            {
                const int w = jmax (32, editor->getWidth());
                const int h = jmax (32, editor->getHeight());

                if (getWidth() != w || getHeight() != h)
                    setSize (w, h);

                NSView* view = (NSView*) getWindowHandle();
                NSRect r = [[view superview] frame];
                r.size.width = editor->getWidth();
                r.size.height = editor->getHeight();
                [[view superview] setFrame: r];
                [view setFrame: makeNSRect (editor->getLocalBounds())];
                [view setNeedsDisplay: YES];
            }
        }

        bool keyPressed (const KeyPress&) override
        {
            if (getHostType().isAbletonLive())
            {
                static NSTimeInterval lastEventTime = 0; // check we're not recursively sending the same event
                NSTimeInterval eventTime = [[NSApp currentEvent] timestamp];

                if (lastEventTime != eventTime)
                {
                    lastEventTime = eventTime;

                    NSView* view = (NSView*) getWindowHandle();
                    NSView* hostView = [view superview];
                    NSWindow* hostWindow = [hostView window];

                    [hostWindow makeFirstResponder: hostView];
                    [hostView keyDown: [NSApp currentEvent]];
                    [hostWindow makeFirstResponder: view];
                }
            }

            return false;
        }

    private:
        FakeMouseMoveGenerator fakeMouseGenerator;

        JUCE_DECLARE_NON_COPYABLE (EditorCompHolder)
    };

    void deleteActiveEditors()
    {
        for (int i = activeUIs.size(); --i >= 0;)
        {
            id ui = (id) activeUIs.getUnchecked(i);

            if (JuceUIViewClass::getAU (ui) == this)
                JuceUIViewClass::deleteEditor (ui);
        }
    }

    //==============================================================================
    struct JuceUIViewClass  : public ObjCClass<NSView>
    {
        JuceUIViewClass()  : ObjCClass<NSView> ("JUCEAUView_")
        {
            addIvar<AudioProcessor*> ("filter");
            addIvar<JuceAU*> ("au");
            addIvar<EditorCompHolder*> ("editor");

            addMethod (@selector (dealloc),                     dealloc,                    "v@:");
            addMethod (@selector (applicationWillTerminate:),   applicationWillTerminate,   "v@:@");
            addMethod (@selector (viewDidMoveToWindow),         viewDidMoveToWindow,        "v@:");
            addMethod (@selector (mouseDownCanMoveWindow),      mouseDownCanMoveWindow,     "c@:");

            registerClass();
        }

        static void deleteEditor (id self)
        {
            ScopedPointer<EditorCompHolder> editorComp (getEditor (self));

            if (editorComp != nullptr)
            {
                if (editorComp->getChildComponent(0) != nullptr
                     && activePlugins.contains (getAU (self))) // plugin may have been deleted before the UI
                {
                    AudioProcessor* const filter = getIvar<AudioProcessor*> (self, "filter");
                    filter->editorBeingDeleted ((AudioProcessorEditor*) editorComp->getChildComponent(0));
                }

                editorComp = nullptr;
                setEditor (self, nullptr);
            }
        }

        static JuceAU* getAU (id self)                          { return getIvar<JuceAU*> (self, "au"); }
        static EditorCompHolder* getEditor (id self)            { return getIvar<EditorCompHolder*> (self, "editor"); }

        static void setFilter (id self, AudioProcessor* filter) { object_setInstanceVariable (self, "filter", filter); }
        static void setAU (id self, JuceAU* au)                 { object_setInstanceVariable (self, "au", au); }
        static void setEditor (id self, EditorCompHolder* e)    { object_setInstanceVariable (self, "editor", e); }

    private:
        static void dealloc (id self, SEL)
        {
            if (activeUIs.contains (self))
                shutdown (self);

            sendSuperclassMessage (self, @selector (dealloc));
        }

        static void applicationWillTerminate (id self, SEL, NSNotification*)
        {
            shutdown (self);
        }

        static void shutdown (id self)
        {
            [[NSNotificationCenter defaultCenter] removeObserver: self];
            deleteEditor (self);

            jassert (activeUIs.contains (self));
            activeUIs.removeFirstMatchingValue (self);

            if (activePlugins.size() + activeUIs.size() == 0)
            {
                // there's some kind of component currently modal, but the host
                // is trying to delete our plugin..
                jassert (Component::getCurrentlyModalComponent() == nullptr);

                shutdownJuce_GUI();
            }
        }

        static void viewDidMoveToWindow (id self, SEL)
        {
            if (NSWindow* w = [(NSView*) self window])
            {
                [w setAcceptsMouseMovedEvents: YES];

                if (EditorCompHolder* const editorComp = getEditor (self))
                    [w makeFirstResponder: (NSView*) editorComp->getWindowHandle()];
            }
        }

        static BOOL mouseDownCanMoveWindow (id, SEL)
        {
            return NO;
        }
    };

    //==============================================================================
    struct JuceUICreationClass  : public ObjCClass<NSObject>
    {
        JuceUICreationClass()  : ObjCClass<NSObject> ("JUCE_AUCocoaViewClass_")
        {
            addMethod (@selector (interfaceVersion),             interfaceVersion,    @encode (unsigned int), "@:");
            addMethod (@selector (description),                  description,         @encode (NSString*),    "@:");
            addMethod (@selector (uiViewForAudioUnit:withSize:), uiViewForAudioUnit,  @encode (NSView*),      "@:", @encode (AudioUnit), @encode (NSSize));

            addProtocol (@protocol (AUCocoaUIBase));

            registerClass();
        }

    private:
        static unsigned int interfaceVersion (id, SEL)   { return 0; }

        static NSString* description (id, SEL)
        {
            return [NSString stringWithString: nsStringLiteral (JucePlugin_Name)];
        }

        static NSView* uiViewForAudioUnit (id, SEL, AudioUnit inAudioUnit, NSSize)
        {
            void* pointers[2];
            UInt32 propertySize = sizeof (pointers);

            if (AudioUnitGetProperty (inAudioUnit, juceFilterObjectPropertyID,
                                      kAudioUnitScope_Global, 0, pointers, &propertySize) == noErr)
            {
                if (AudioProcessor* filter = static_cast<AudioProcessor*> (pointers[0]))
                    if (AudioProcessorEditor* editorComp = filter->createEditorIfNeeded())
                        return EditorCompHolder::createViewFor (filter, static_cast<JuceAU*> (pointers[1]), editorComp);
            }

            return nil;
        }
    };

private:
    //==============================================================================
    AudioUnitHelpers::CoreAudioBufferList audioBuffer;
    MidiBuffer midiEvents, incomingEvents;
    bool prepared, isBypassed;

    //==============================================================================
   #if ! JUCE_FORCE_USE_LEGACY_PARAM_IDS
    bool usingManagedParameter;
    Array<AudioUnitParameterID> auParamIDs;
    HashMap<int32, int> paramMap;
   #endif

    //==============================================================================
    AudioUnitEvent auEvent;
    mutable Array<AUPreset> presetsArray;
    CriticalSection incomingMidiLock;
    AUMIDIOutputCallbackStruct midiCallback;
    AudioTimeStamp lastTimeStamp;
    PluginBusUtilities busUtils;
    int totalInChannels, totalOutChannels;

    //==============================================================================
    Array<AUChannelInfo> channelInfo;
    Array<Array<AudioChannelLayoutTag> > supportedInputLayouts, supportedOutputLayouts;
    Array<AudioChannelLayoutTag> currentInputLayout, currentOutputLayout;

    //==============================================================================
    AudioUnitHelpers::ChannelRemapper mapper;

    //==============================================================================
    bool pullInputAudio (AudioUnitRenderActionFlags& flags, const AudioTimeStamp& timestamp, const UInt32 nFrames) noexcept
    {
        const unsigned int numInputBuses = GetScope (kAudioUnitScope_Input).GetNumberOfElements();

        for (unsigned int i = 0; i < numInputBuses; ++i)
        {
            if (AUInputElement* input = GetInput (i))
            {
                if (input->PullInput (flags, timestamp, i, nFrames) != noErr)
                    return false; // logic sometimes doesn't connect all the inputs immedietely

                if ((flags & kAudioUnitRenderAction_OutputIsSilence) != 0)
                    AudioUnitHelpers::clearAudioBuffer (input->GetBufferList());
            }
        }

        return true;
    }

    void prepareOutputBuffers (const UInt32 nFrames) noexcept
    {
        const unsigned int numOutputBuses = GetScope (kAudioUnitScope_Output).GetNumberOfElements();

        for (unsigned int busIdx = 0; busIdx < numOutputBuses; ++busIdx)
        {
            AUOutputElement* output = GetOutput (busIdx);

            if (output->WillAllocateBuffer())
                output->PrepareBuffer (nFrames);
        }
    }

    void processBlock (AudioSampleBuffer& buffer, MidiBuffer& midiBuffer) noexcept
    {
        const ScopedLock sl (juceFilter->getCallbackLock());

        if (juceFilter->isSuspended())
        {
            buffer.clear();
        }
        else if (isBypassed)
        {
            juceFilter->processBlockBypassed (buffer, midiBuffer);
        }
        else
        {
            juceFilter->processBlock (buffer, midiBuffer);
        }
    }

    void pushMidiOutput (UInt32 nFrames) noexcept
    {
        UInt32 numPackets = 0;
        size_t dataSize = 0;

        const juce::uint8* midiEventData;
        int midiEventSize, midiEventPosition;

        for (MidiBuffer::Iterator i (midiEvents); i.getNextEvent (midiEventData, midiEventSize, midiEventPosition);)
        {
            jassert (isPositiveAndBelow (midiEventPosition, (int) nFrames));
            ignoreUnused (nFrames);

            dataSize += (size_t) midiEventSize;
            ++numPackets;
        }

        MIDIPacket* p;
        const size_t packetMembersSize     = sizeof (MIDIPacket)     - sizeof (p->data); // NB: GCC chokes on "sizeof (MidiMessage::data)"
        const size_t packetListMembersSize = sizeof (MIDIPacketList) - sizeof (p->data);

        HeapBlock<MIDIPacketList> packetList;
        packetList.malloc (packetListMembersSize + packetMembersSize * numPackets + dataSize, 1);
        packetList->numPackets = numPackets;

        p = packetList->packet;

        for (MidiBuffer::Iterator i (midiEvents); i.getNextEvent (midiEventData, midiEventSize, midiEventPosition);)
        {
            p->timeStamp = (MIDITimeStamp) midiEventPosition;
            p->length = (UInt16) midiEventSize;
            memcpy (p->data, midiEventData, (size_t) midiEventSize);
            p = MIDIPacketNext (p);
        }

        midiCallback.midiOutputCallback (midiCallback.userData, &lastTimeStamp, 0, packetList);
    }

    bool GetAudioBufferList (bool isInput, int busIdx, AudioBufferList*& bufferList, bool& interleaved, int& numChannels)
    {
        if (AUIOElement* element = GetElement (isInput ? kAudioUnitScope_Input : kAudioUnitScope_Output, static_cast<UInt32> (busIdx))->AsIOElement())
        {
            bufferList = &element->GetBufferList();

            if (bufferList->mNumberBuffers > 0)
            {
                interleaved = AudioUnitHelpers::isAudioBufferInterleaved (*bufferList);
                numChannels = static_cast<int> (interleaved ? bufferList->mBuffers[0].mNumberChannels : bufferList->mNumberBuffers);
                return true;
            }
        }

        return false;
    }

    //==============================================================================
    static OSStatus scopeToDirection (AudioUnitScope scope, bool& isInput) noexcept
    {
        isInput = (scope == kAudioUnitScope_Input);

        return (scope != kAudioUnitScope_Input
             && scope != kAudioUnitScope_Output)
              ? kAudioUnitErr_InvalidScope : noErr;
    }

    OSStatus elementToBusIdx (AudioUnitScope scope, AudioUnitElement element, bool& isInput, int& busIdx) noexcept
    {
        OSStatus err;

        busIdx = static_cast<int> (element);

        if ((err = scopeToDirection (scope, isInput)) != noErr) return err;
        if (isPositiveAndBelow (busIdx, busUtils.getBusCount (isInput))) return noErr;

        return kAudioUnitErr_InvalidElement;
    }

    //==============================================================================
    void addParameters()
    {
        // check if all parameters are managed?
        const int numParams = juceFilter->getNumParameters();

      #if ! JUCE_FORCE_USE_LEGACY_PARAM_IDS
        usingManagedParameter = (juceFilter->getParameters().size() == numParams);

        if (usingManagedParameter)
        {
            const int n = juceFilter->getNumParameters();

            for (int i = 0; i < n; ++i)
            {
                const AudioUnitParameterID auParamID = generateAUParameterIDForIndex (i);

                // Consider yourself very unlucky if you hit this assertion. The hash code of your
                // parameter ids are not unique.
                jassert (! paramMap.contains (static_cast<int32> (auParamID)));

                auParamIDs.add (auParamID);
                paramMap.set (static_cast<int32> (auParamID), i);

                Globals()->SetParameter (auParamID, juceFilter->getParameter (i));
            }
        }
        else
       #endif
        {
            Globals()->UseIndexedParameters (numParams);
        }
    }

    //==============================================================================
   #if JUCE_FORCE_USE_LEGACY_PARAM_IDS
    inline AudioUnitParameterID getAUParameterIDForIndex (int paramIndex) const noexcept    { return static_cast<AudioUnitParameterID> (paramIndex); }
    inline int getJuceIndexForAUParameterID (AudioUnitParameterID address) const noexcept   { return static_cast<int> (address); }
   #else
    AudioUnitParameterID generateAUParameterIDForIndex (int paramIndex) const
    {
        const int n = juceFilter->getNumParameters();

        if (isPositiveAndBelow (paramIndex, n))
        {
            const String& juceParamID = juceFilter->getParameterID (paramIndex);
            return usingManagedParameter ? static_cast<AudioUnitParameterID> (juceParamID.hashCode())
                                         : static_cast<AudioUnitParameterID> (juceParamID.getIntValue());
        }

        return static_cast<AudioUnitParameterID> (-1);
    }

    inline AudioUnitParameterID getAUParameterIDForIndex (int paramIndex) const noexcept
    {
        return usingManagedParameter ? auParamIDs.getReference (paramIndex)
                                     : static_cast<AudioUnitParameterID> (paramIndex);
    }

    inline int getJuceIndexForAUParameterID (AudioUnitParameterID address) const noexcept
    {
        return usingManagedParameter ? paramMap[static_cast<int32> (address)]
                                     : static_cast<int> (address);
    }
   #endif


    //==============================================================================
    OSStatus syncAudioUnitWithProcessor()
    {
        OSStatus err = noErr;
        const int enabledInputs  = busUtils.getNumEnabledBuses (true);
        const int enabledOutputs = busUtils.getNumEnabledBuses (false);

        if ((err =  MusicDeviceBase::SetBusCount (kAudioUnitScope_Input,  static_cast<UInt32> (enabledInputs))) != noErr)
            return err;

        if ((err =  MusicDeviceBase::SetBusCount (kAudioUnitScope_Output, static_cast<UInt32> (enabledOutputs))) != noErr)
            return err;

        addSupportedLayoutTags();

        for (int i = 0; i < juceFilter->busArrangement.inputBuses.size(); ++i)
            if ((err = syncAudioUnitWithChannelSet (true, i,  busUtils.getChannelSet (true,  i))) != noErr) return err;

        for (int i = 0; i < juceFilter->busArrangement.outputBuses.size(); ++i)
            if ((err = syncAudioUnitWithChannelSet (false, i, busUtils.getChannelSet (false, i))) != noErr) return err;

        // if you are hitting this assertion then your plug-in allows disabling/enabling buses (i.e. you
        // do not return false in setPreferredBusArrangement when the number of channels is zero), however,
        // AudioUnits require at least the main bus to be enabled by default in this case. Please assign
        // a non-zero number of channels to your main input or output bus in the constructor of your AudioProcessor
        jassert ((! busUtils.hasDynamicInBuses() && ! busUtils.hasDynamicOutBuses()) || (enabledInputs > 0) || (enabledOutputs > 0));

        return noErr;
    }

    OSStatus syncProcessorWithAudioUnit()
    {
        OSStatus err;
        const int numInputBuses  = busUtils.getBusCount (true);
        const int numOutputBuses = busUtils.getBusCount (false);

        const int numInputElements  = static_cast<int> (GetScope(kAudioUnitScope_Input). GetNumberOfElements());
        const int numOutputElements = static_cast<int> (GetScope(kAudioUnitScope_Output).GetNumberOfElements());

        for (int i = 0; i < numInputBuses; ++i)
            if ((err = syncProcessorWithAudioUnitForBus (true, i)) != noErr) return err;

        for (int i = 0; i < numOutputBuses; ++i)
            if ((err = syncProcessorWithAudioUnitForBus (false, i)) != noErr) return err;

        if (numInputElements != busUtils.getNumEnabledBuses (true) || numOutputElements != busUtils.getNumEnabledBuses (false))
            return kAudioUnitErr_FormatNotSupported;

        // re-check the format of all buses to see if it matches what CoreAudio actually requested
        for (int i = 0; i < busUtils.getNumEnabledBuses (true); ++i)
            if (! audioUnitAndProcessorIsFormatMatching (true, i)) return kAudioUnitErr_FormatNotSupported;

        for (int i = 0; i < busUtils.getNumEnabledBuses (false); ++i)
            if (! audioUnitAndProcessorIsFormatMatching (false, i)) return kAudioUnitErr_FormatNotSupported;

        // update total channel count
        totalInChannels = busUtils.findTotalNumChannels (true);
        totalOutChannels = busUtils.findTotalNumChannels (false);

        return noErr;
    }

    //==============================================================================
    OSStatus syncProcessorWithAudioUnitForBus (bool isInput, int busNr)
    {
        jassert (isPositiveAndBelow (busNr, busUtils.getBusCount (isInput)));

        const int numAUElements  = static_cast<int> (GetScope(isInput ? kAudioUnitScope_Input : kAudioUnitScope_Output).GetNumberOfElements());
        const AUIOElement* element = (busNr < numAUElements ? GetIOElement (isInput ? kAudioUnitScope_Input :  kAudioUnitScope_Output, (UInt32) busNr) : nullptr);
        const int numChannels = (element != nullptr ? static_cast<int> (element->GetStreamFormat().NumberChannels()) : 0);

        AudioChannelLayoutTag currentLayoutTag = isInput ? currentInputLayout[busNr] : currentOutputLayout[busNr];
        const int tagNumChannels = currentLayoutTag & 0xffff;

        if (numChannels != tagNumChannels)
            return kAudioUnitErr_FormatNotSupported;

        const AudioChannelSet channelFormat = AudioUnitHelpers::CALayoutTagToChannelSet(currentLayoutTag);

        if (! juceFilter->setPreferredBusArrangement (isInput, busNr, channelFormat))
            return kAudioUnitErr_FormatNotSupported;

        return noErr;
    }

    OSStatus syncAudioUnitWithChannelSet (bool isInput, int busNr, const AudioChannelSet& channelSet)
    {
        const int numChannels = channelSet.size();

        getCurrentLayout (isInput, busNr) = AudioUnitHelpers::ChannelSetToCALayoutTag (channelSet);

        // is this bus activated?
        if (numChannels == 0)
            return noErr;

        if (AUIOElement* element = GetIOElement (isInput ? kAudioUnitScope_Input :  kAudioUnitScope_Output, (UInt32) busNr))
        {
            element->SetName ((CFStringRef) juceStringToNS (busUtils.getFilterBus (isInput).getReference (busNr).name));

            CAStreamBasicDescription streamDescription;
            streamDescription.mSampleRate = getSampleRate();

            streamDescription.SetCanonical ((UInt32) numChannels, false);
            return element->SetStreamFormat (streamDescription);
        }
        else
            jassertfalse;

        return kAudioUnitErr_InvalidElement;
    }

    //==============================================================================
    bool audioUnitAndProcessorIsFormatMatching (bool isInput, int busNr)
    {
        const AudioProcessor::AudioProcessorBus& bus = isInput ? juceFilter->busArrangement.inputBuses. getReference (busNr)
        : juceFilter->busArrangement.outputBuses.getReference (busNr);

        if (const AUIOElement* element = GetIOElement (isInput ? kAudioUnitScope_Input :  kAudioUnitScope_Output, (UInt32) busNr))
        {
            const int numChannels = static_cast<int> (element->GetStreamFormat().NumberChannels());

            return (numChannels == bus.channels.size());
        }
        else
            jassertfalse;

        return false;
    }

    //==============================================================================
    void clearPresetsArray() const
    {
        for (int i = presetsArray.size(); --i >= 0;)
            CFRelease (presetsArray.getReference(i).presetName);

        presetsArray.clear();
    }

    void refreshCurrentPreset()
    {
        // this will make the AU host re-read and update the current preset name
        // in case it was changed here in the plug-in:

        const int currentProgramNumber = juceFilter->getCurrentProgram();
        const String currentProgramName = juceFilter->getProgramName (currentProgramNumber);

        AUPreset currentPreset;
        currentPreset.presetNumber = currentProgramNumber;
        currentPreset.presetName = currentProgramName.toCFString();

        SetAFactoryPresetAsCurrent (currentPreset);
    }

    //==============================================================================
    Array<AudioChannelLayoutTag>&       getSupportedBusLayouts (bool isInput, int bus) noexcept       { return (isInput ? supportedInputLayouts : supportedOutputLayouts).getReference (bus); }
    const Array<AudioChannelLayoutTag>& getSupportedBusLayouts (bool isInput, int bus) const noexcept { return (isInput ? supportedInputLayouts : supportedOutputLayouts).getReference (bus); }
    AudioChannelLayoutTag& getCurrentLayout (bool isInput, int bus) noexcept               { return (isInput ? currentInputLayout : currentOutputLayout).getReference (bus); }
    AudioChannelLayoutTag  getCurrentLayout (bool isInput, int bus) const noexcept         { return (isInput ? currentInputLayout : currentOutputLayout)[bus]; }

    bool toggleBus (bool isInput, int busIdx)
    {
        if (busUtils.busCanBeDisabled (isInput, busIdx))
            return false;

        AudioChannelSet newSet;

        if (! busUtils.isBusEnabled (isInput, busIdx))
            newSet = busUtils.getDefaultLayoutForBus (isInput, busIdx);

        return juceFilter->setPreferredBusArrangement (isInput, busIdx, newSet);
    }

    //==============================================================================
    void addSupportedLayoutTagsForBus (bool isInput, int busNum, Array<AudioChannelLayoutTag>& tags)
    {
        int layoutIndex;
        AudioChannelLayoutTag tag;

        for (layoutIndex = 0; (tag = AudioUnitHelpers::auChannelStreamOrder[layoutIndex].auLayoutTag) != 0; ++layoutIndex)
            if (juceFilter->setPreferredBusArrangement (isInput, busNum, AudioUnitHelpers::CALayoutTagToChannelSet (tag)))
                tags.add (tag);

        // add discrete layout tags
        int n = busUtils.findMaxNumberOfChannelsForBus (true, busNum);
        n = n < 0 ? maxChannelsToProbeFor() : n;

        for (int ch = 0; ch < n; ++ch)
        {
            if (juceFilter->setPreferredBusArrangement (isInput, busNum, AudioChannelSet::discreteChannels (ch)))
                tags.add (static_cast<AudioChannelLayoutTag> ((int) kAudioChannelLayoutTag_DiscreteInOrder | ch));
        }
    }

    void addSupportedLayoutTagsForDirection (bool isInput)
    {
        Array<Array<AudioChannelLayoutTag> >& layouts = isInput ? supportedInputLayouts : supportedOutputLayouts;
        layouts.clear();

        for (int busNr = 0; busNr < busUtils.getBusCount (isInput); ++busNr)
        {
            Array<AudioChannelLayoutTag> busLayouts;
            addSupportedLayoutTagsForBus (isInput, busNr, busLayouts);

            layouts.add (busLayouts);
        }
    }

    void addSupportedLayoutTags()
    {
        currentInputLayout.clear(); currentOutputLayout.clear();

        currentInputLayout. resize (juceFilter->busArrangement.inputBuses. size());
        currentOutputLayout.resize (juceFilter->busArrangement.outputBuses.size());

        PluginBusUtilities::ScopedBusRestorer busRestorer (busUtils);
        addSupportedLayoutTagsForDirection (true);
        addSupportedLayoutTagsForDirection (false);
    }

    static int maxChannelsToProbeFor()
    {
        return (getHostType().isLogic() ? 8 : 64);
    }

    JUCE_DECLARE_NON_COPYABLE (JuceAU)
};

//==============================================================================
#if BUILD_AU_CARBON_UI

class JuceAUView  : public AUCarbonViewBase
{
public:
    JuceAUView (AudioUnitCarbonView auview)
      : AUCarbonViewBase (auview),
        juceFilter (nullptr)
    {
    }

    ~JuceAUView()
    {
        deleteUI();
    }

    ComponentResult CreateUI (Float32 /*inXOffset*/, Float32 /*inYOffset*/) override
    {
        JUCE_AUTORELEASEPOOL
        {
            if (juceFilter == nullptr)
            {
                void* pointers[2];
                UInt32 propertySize = sizeof (pointers);

                AudioUnitGetProperty (GetEditAudioUnit(),
                                      juceFilterObjectPropertyID,
                                      kAudioUnitScope_Global,
                                      0,
                                      pointers,
                                      &propertySize);

                juceFilter = (AudioProcessor*) pointers[0];
            }

            if (juceFilter != nullptr)
            {
                deleteUI();

                if (AudioProcessorEditor* editorComp = juceFilter->createEditorIfNeeded())
                {
                    editorComp->setOpaque (true);
                    windowComp = new ComponentInHIView (editorComp, mCarbonPane);
                }
            }
            else
            {
                jassertfalse; // can't get a pointer to our effect
            }
        }

        return noErr;
    }

    AudioUnitCarbonViewEventListener getEventListener() const   { return mEventListener; }
    void* getEventListenerUserData() const                      { return mEventListenerUserData; }

private:
    //==============================================================================
    AudioProcessor* juceFilter;
    ScopedPointer<Component> windowComp;
    FakeMouseMoveGenerator fakeMouseGenerator;

    void deleteUI()
    {
        if (windowComp != nullptr)
        {
            PopupMenu::dismissAllActiveMenus();

            /* This assertion is triggered when there's some kind of modal component active, and the
               host is trying to delete our plugin.
               If you must use modal components, always use them in a non-blocking way, by never
               calling runModalLoop(), but instead using enterModalState() with a callback that
               will be performed on completion. (Note that this assertion could actually trigger
               a false alarm even if you're doing it correctly, but is here to catch people who
               aren't so careful) */
            jassert (Component::getCurrentlyModalComponent() == nullptr);

            if (JuceAU::EditorCompHolder* editorCompHolder = dynamic_cast<JuceAU::EditorCompHolder*> (windowComp->getChildComponent(0)))
                if (AudioProcessorEditor* audioProcessEditor = dynamic_cast<AudioProcessorEditor*> (editorCompHolder->getChildComponent(0)))
                    juceFilter->editorBeingDeleted (audioProcessEditor);

            windowComp = nullptr;
        }
    }

    //==============================================================================
    // Uses a child NSWindow to sit in front of a HIView and display our component
    class ComponentInHIView  : public Component
    {
    public:
        ComponentInHIView (AudioProcessorEditor* ed, HIViewRef parentHIView)
            : parentView (parentHIView),
              editor (ed),
              recursive (false)
        {
            JUCE_AUTORELEASEPOOL
            {
                jassert (ed != nullptr);
                addAndMakeVisible (editor);
                setOpaque (true);
                setVisible (true);
                setBroughtToFrontOnMouseClick (true);

                setSize (editor.getWidth(), editor.getHeight());
                SizeControl (parentHIView, (SInt16) editor.getWidth(), (SInt16) editor.getHeight());

                WindowRef windowRef = HIViewGetWindow (parentHIView);
                hostWindow = [[NSWindow alloc] initWithWindowRef: windowRef];

                [hostWindow retain];
                [hostWindow setCanHide: YES];
                [hostWindow setReleasedWhenClosed: YES];

                updateWindowPos();

               #if ! JucePlugin_EditorRequiresKeyboardFocus
                addToDesktop (ComponentPeer::windowIsTemporary | ComponentPeer::windowIgnoresKeyPresses);
                setWantsKeyboardFocus (false);
               #else
                addToDesktop (ComponentPeer::windowIsTemporary);
                setWantsKeyboardFocus (true);
               #endif

                setVisible (true);
                toFront (false);

                addSubWindow();

                NSWindow* pluginWindow = [((NSView*) getWindowHandle()) window];
                [pluginWindow setNextResponder: hostWindow];

                attachWindowHidingHooks (this, (WindowRef) windowRef, hostWindow);
            }
        }

        ~ComponentInHIView()
        {
            JUCE_AUTORELEASEPOOL
            {
                removeWindowHidingHooks (this);

                NSWindow* pluginWindow = [((NSView*) getWindowHandle()) window];
                [hostWindow removeChildWindow: pluginWindow];
                removeFromDesktop();

                [hostWindow release];
                hostWindow = nil;
            }
        }

        void updateWindowPos()
        {
            HIPoint f;
            f.x = f.y = 0;
            HIPointConvert (&f, kHICoordSpaceView, parentView, kHICoordSpaceScreenPixel, 0);
            setTopLeftPosition ((int) f.x, (int) f.y);
        }

        void addSubWindow()
        {
            NSWindow* pluginWindow = [((NSView*) getWindowHandle()) window];
            [pluginWindow setExcludedFromWindowsMenu: YES];
            [pluginWindow setCanHide: YES];

            [hostWindow addChildWindow: pluginWindow
                               ordered: NSWindowAbove];
            [hostWindow orderFront: nil];
            [pluginWindow orderFront: nil];
        }

        void resized() override
        {
            if (Component* const child = getChildComponent (0))
                child->setBounds (getLocalBounds());
        }

        void paint (Graphics&) override {}

        void childBoundsChanged (Component*) override
        {
            if (! recursive)
            {
                recursive = true;

                const int w = jmax (32, editor.getWidth());
                const int h = jmax (32, editor.getHeight());

                SizeControl (parentView, (SInt16) w, (SInt16) h);

                if (getWidth() != w || getHeight() != h)
                    setSize (w, h);

                editor.repaint();

                updateWindowPos();
                addSubWindow(); // (need this for AULab)

                recursive = false;
            }
        }

        bool keyPressed (const KeyPress& kp) override
        {
            if (! kp.getModifiers().isCommandDown())
            {
                // If we have an unused keypress, move the key-focus to a host window
                // and re-inject the event..
                static NSTimeInterval lastEventTime = 0; // check we're not recursively sending the same event
                NSTimeInterval eventTime = [[NSApp currentEvent] timestamp];

                if (lastEventTime != eventTime)
                {
                    lastEventTime = eventTime;

                    [[hostWindow parentWindow] makeKeyWindow];
                    repostCurrentNSEvent();
                }
            }

            return false;
        }

    private:
        HIViewRef parentView;
        NSWindow* hostWindow;
        JuceAU::EditorCompHolder editor;
        bool recursive;
    };
};

#endif

//==============================================================================
#define JUCE_COMPONENT_ENTRYX(Class, Name, Suffix) \
    extern "C" __attribute__((visibility("default"))) ComponentResult Name ## Suffix (ComponentParameters* params, Class* obj); \
    extern "C" __attribute__((visibility("default"))) ComponentResult Name ## Suffix (ComponentParameters* params, Class* obj) \
    { \
        PluginHostType::jucePlugInClientCurrentWrapperType = AudioProcessor::wrapperType_AudioUnit; \
        return ComponentEntryPoint<Class>::Dispatch (params, obj); \
    }

#if JucePlugin_ProducesMidiOutput || JucePlugin_WantsMidiInput || JucePlugin_IsMidiEffect
 #define FACTORY_BASE_CLASS AUMIDIEffectFactory
#else
 #define FACTORY_BASE_CLASS AUBaseFactory
#endif

#define JUCE_FACTORY_ENTRYX(Class, Name) \
    extern "C" __attribute__((visibility("default"))) void* Name ## Factory (const AudioComponentDescription* desc); \
    extern "C" __attribute__((visibility("default"))) void* Name ## Factory (const AudioComponentDescription* desc) \
    { \
        PluginHostType::jucePlugInClientCurrentWrapperType = AudioProcessor::wrapperType_AudioUnit; \
        return FACTORY_BASE_CLASS<Class>::Factory (desc); \
    }

#define JUCE_COMPONENT_ENTRY(Class, Name, Suffix)   JUCE_COMPONENT_ENTRYX(Class, Name, Suffix)
#define JUCE_FACTORY_ENTRY(Class, Name)             JUCE_FACTORY_ENTRYX(Class, Name)

//==============================================================================
JUCE_COMPONENT_ENTRY (JuceAU, JucePlugin_AUExportPrefix, Entry)

#ifndef AUDIOCOMPONENT_ENTRY
 #define JUCE_DISABLE_AU_FACTORY_ENTRY 1
#endif

#if ! JUCE_DISABLE_AU_FACTORY_ENTRY  // (You might need to disable this for old Xcode 3 builds)
JUCE_FACTORY_ENTRY   (JuceAU, JucePlugin_AUExportPrefix)
#endif

#if BUILD_AU_CARBON_UI
 JUCE_COMPONENT_ENTRY (JuceAUView, JucePlugin_AUExportPrefix, ViewEntry)
#endif

#if ! JUCE_DISABLE_AU_FACTORY_ENTRY
 #include "CoreAudioUtilityClasses/AUPlugInDispatch.cpp"
#endif

#endif
