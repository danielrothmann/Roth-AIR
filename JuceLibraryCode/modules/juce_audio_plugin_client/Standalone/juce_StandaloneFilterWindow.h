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

#ifndef JUCE_STANDALONEFILTERWINDOW_H_INCLUDED
#define JUCE_STANDALONEFILTERWINDOW_H_INCLUDED

//==============================================================================
/**
    An object that creates and plays a standalone instance of an AudioProcessor.

    The object will create your processor using the same createPluginFilter()
    function that the other plugin wrappers use, and will run it through the
    computer's audio/MIDI devices using AudioDeviceManager and AudioProcessorPlayer.
*/
class StandalonePluginHolder
   #if JUCE_IOS || JUCE_ANDROID
    : private Timer
   #endif
{
public:
    /** Creates an instance of the default plugin.

        The settings object can be a PropertySet that the class should use to store its
        settings - the takeOwnershipOfSettings indicates whether this object will delete
        the settings automatically when no longer needed. The settings can also be nullptr.

        A default device name can be passed in.

        Preferably a complete setup options object can be used, which takes precedence over
        the preferredDefaultDeviceName and allows you to select the input & output device names,
        sample rate, buffer size etc.

        In all instances, the settingsToUse will take precedence over the "preferred" options if not null.
    */
    StandalonePluginHolder (PropertySet* settingsToUse,
                            bool takeOwnershipOfSettings = true,
                            const String& preferredDefaultDeviceName = String(),
                            const AudioDeviceManager::AudioDeviceSetup* preferredSetupOptions = nullptr)

        : settings (settingsToUse, takeOwnershipOfSettings)
    {
        createPlugin();
        setupAudioDevices (preferredDefaultDeviceName, preferredSetupOptions);
        reloadPluginState();
        startPlaying();

       #if JUCE_IOS || JUCE_ANDROID
        startTimer (500);
       #endif
    }

    virtual ~StandalonePluginHolder()
    {
       #if JUCE_IOS || JUCE_ANDROID
        stopTimer();
       #endif

        deletePlugin();
        shutDownAudioDevices();
    }

    //==============================================================================
    virtual void createPlugin()
    {

      #if JUCE_MODULE_AVAILABLE_juce_audio_plugin_client
        processor = ::createPluginFilterOfType (AudioProcessor::wrapperType_Standalone);
      #else
        AudioProcessor::setTypeOfNextNewPlugin (AudioProcessor::wrapperType_Standalone);
        processor = createPluginFilter();
        AudioProcessor::setTypeOfNextNewPlugin (AudioProcessor::wrapperType_Undefined);
      #endif
        jassert (processor != nullptr); // Your createPluginFilter() function must return a valid object!

        // try to disable sidechain and aux buses
        const int numInBuses  = processor->busArrangement.inputBuses. size();
        const int numOutBuses = processor->busArrangement.outputBuses.size();

        for (int busIdx = 1; busIdx < numInBuses; ++busIdx)
            processor->setPreferredBusArrangement (true, busIdx, AudioChannelSet::disabled());

        for (int busIdx = 1; busIdx < numOutBuses; ++busIdx)
            processor->setPreferredBusArrangement (false, busIdx, AudioChannelSet::disabled());

        processor->setRateAndBufferSizeDetails(44100, 512);
    }

    virtual void deletePlugin()
    {
        stopPlaying();
        processor = nullptr;
    }

    static String getFilePatterns (const String& fileSuffix)
    {
        if (fileSuffix.isEmpty())
            return String();

        return (fileSuffix.startsWithChar ('.') ? "*" : "*.") + fileSuffix;
    }


    //==============================================================================
    File getLastFile() const
    {
        File f;

        if (settings != nullptr)
            f = File (settings->getValue ("lastStateFile"));

        if (f == File())
            f = File::getSpecialLocation (File::userDocumentsDirectory);

        return f;
    }

    void setLastFile (const FileChooser& fc)
    {
        if (settings != nullptr)
            settings->setValue ("lastStateFile", fc.getResult().getFullPathName());
    }

    /** Pops up a dialog letting the user save the processor's state to a file. */
    void askUserToSaveState (const String& fileSuffix = String())
    {
       #if JUCE_MODAL_LOOPS_PERMITTED
        FileChooser fc (TRANS("Save current state"), getLastFile(), getFilePatterns (fileSuffix));

        if (fc.browseForFileToSave (true))
        {
            setLastFile (fc);

            MemoryBlock data;
            processor->getStateInformation (data);

            if (! fc.getResult().replaceWithData (data.getData(), data.getSize()))
                AlertWindow::showMessageBoxAsync (AlertWindow::WarningIcon,
                                                  TRANS("Error whilst saving"),
                                                  TRANS("Couldn't write to the specified file!"));
        }
       #else
        ignoreUnused (fileSuffix);
       #endif
    }

    /** Pops up a dialog letting the user re-load the processor's state from a file. */
    void askUserToLoadState (const String& fileSuffix = String())
    {
       #if JUCE_MODAL_LOOPS_PERMITTED
        FileChooser fc (TRANS("Load a saved state"), getLastFile(), getFilePatterns (fileSuffix));

        if (fc.browseForFileToOpen())
        {
            setLastFile (fc);

            MemoryBlock data;

            if (fc.getResult().loadFileAsData (data))
                processor->setStateInformation (data.getData(), (int) data.getSize());
            else
                AlertWindow::showMessageBoxAsync (AlertWindow::WarningIcon,
                                                  TRANS("Error whilst loading"),
                                                  TRANS("Couldn't read from the specified file!"));
        }
       #else
        ignoreUnused (fileSuffix);
       #endif
    }

    //==============================================================================
    void startPlaying()
    {
        player.setProcessor (processor);
    }

    void stopPlaying()
    {
        player.setProcessor (nullptr);
    }

    //==============================================================================
    /** Shows an audio properties dialog box modally. */
    void showAudioSettingsDialog()
    {
        DialogWindow::LaunchOptions o;
        o.content.setOwned (new AudioDeviceSelectorComponent (deviceManager,
                                                              processor->getTotalNumInputChannels(),
                                                              processor->getTotalNumInputChannels(),
                                                              processor->getTotalNumOutputChannels(),
                                                              processor->getTotalNumOutputChannels(),
                                                              true, false,
                                                              true, false));
        o.content->setSize (500, 450);

        o.dialogTitle                   = TRANS("Audio Settings");
        o.dialogBackgroundColour        = Colour (0xfff0f0f0);
        o.escapeKeyTriggersCloseButton  = true;
        o.useNativeTitleBar             = true;
        o.resizable                     = false;

        o.launchAsync();
    }

    void saveAudioDeviceState()
    {
        if (settings != nullptr)
        {
            ScopedPointer<XmlElement> xml (deviceManager.createStateXml());
            settings->setValue ("audioSetup", xml);
        }
    }

    void reloadAudioDeviceState (const String& preferredDefaultDeviceName,
                                 const AudioDeviceManager::AudioDeviceSetup* preferredSetupOptions)
    {
        ScopedPointer<XmlElement> savedState;

        if (settings != nullptr)
            savedState = settings->getXmlValue ("audioSetup");

        deviceManager.initialise (processor->getTotalNumInputChannels(),
                                  processor->getTotalNumOutputChannels(),
                                  savedState,
                                  true,
                                  preferredDefaultDeviceName,
                                  preferredSetupOptions);
    }

    //==============================================================================
    void savePluginState()
    {
        if (settings != nullptr && processor != nullptr)
        {
            MemoryBlock data;
            processor->getStateInformation (data);

            settings->setValue ("filterState", data.toBase64Encoding());
        }
    }

    void reloadPluginState()
    {
        if (settings != nullptr)
        {
            MemoryBlock data;

            if (data.fromBase64Encoding (settings->getValue ("filterState")) && data.getSize() > 0)
                processor->setStateInformation (data.getData(), (int) data.getSize());
        }
    }

    //==============================================================================
    OptionalScopedPointer<PropertySet> settings;
    ScopedPointer<AudioProcessor> processor;
    AudioDeviceManager deviceManager;
    AudioProcessorPlayer player;

   #if JUCE_IOS || JUCE_ANDROID
    StringArray lastMidiDevices;
   #endif

private:
    void setupAudioDevices (const String& preferredDefaultDeviceName,
                            const AudioDeviceManager::AudioDeviceSetup* preferredSetupOptions)
    {
        deviceManager.addAudioCallback (&player);
        deviceManager.addMidiInputCallback (String(), &player);

        reloadAudioDeviceState (preferredDefaultDeviceName, preferredSetupOptions);
    }

    void shutDownAudioDevices()
    {
        saveAudioDeviceState();

        deviceManager.removeMidiInputCallback (String(), &player);
        deviceManager.removeAudioCallback (&player);
    }

   #if JUCE_IOS || JUCE_ANDROID
    void timerCallback() override
    {
        StringArray midiInputDevices = MidiInput::getDevices();
        if (midiInputDevices != lastMidiDevices)
        {
            {
                const int n = lastMidiDevices.size();
                for (int i = 0; i < n; ++i)
                {
                    const String& oldDevice = lastMidiDevices[i];

                    if (! midiInputDevices.contains (oldDevice))
                    {
                        deviceManager.setMidiInputEnabled (oldDevice, false);
                        deviceManager.removeMidiInputCallback (oldDevice, &player);
                    }
                }
            }

            {
                const int n = midiInputDevices.size();
                for (int i = 0; i < n; ++i)
                {
                    const String& newDevice = midiInputDevices[i];

                    if (! lastMidiDevices.contains (newDevice))
                    {
                        deviceManager.addMidiInputCallback (newDevice, &player);
                        deviceManager.setMidiInputEnabled (newDevice, true);
                    }
                }
            }
        }
    }
   #endif

    JUCE_DECLARE_NON_COPYABLE_WITH_LEAK_DETECTOR (StandalonePluginHolder)
};


//==============================================================================
/**
    A class that can be used to run a simple standalone application containing your filter.

    Just create one of these objects in your JUCEApplicationBase::initialise() method, and
    let it do its work. It will create your filter object using the same createPluginFilter() function
    that the other plugin wrappers use.
*/
class StandaloneFilterWindow    : public DocumentWindow,
                                  public ButtonListener   // (can't use Button::Listener due to VC2005 bug)
{
public:
    //==============================================================================
    /** Creates a window with a given title and colour.
        The settings object can be a PropertySet that the class should use to
        store its settings (it can also be null). If takeOwnershipOfSettings is
        true, then the settings object will be owned and deleted by this object.
    */
    StandaloneFilterWindow (const String& title,
                            Colour backgroundColour,
                            PropertySet* settingsToUse,
                            bool takeOwnershipOfSettings,
                            const String& preferredDefaultDeviceName = String(),
                            const AudioDeviceManager::AudioDeviceSetup* preferredSetupOptions = nullptr)
        : DocumentWindow (title, backgroundColour, DocumentWindow::minimiseButton | DocumentWindow::closeButton),
          optionsButton ("options")
    {
        setTitleBarButtonsRequired (DocumentWindow::minimiseButton | DocumentWindow::closeButton, false);

        Component::addAndMakeVisible (optionsButton);
        optionsButton.addListener (this);
        optionsButton.setTriggeredOnMouseDown (true);

        pluginHolder = new StandalonePluginHolder (settingsToUse, takeOwnershipOfSettings,
                                                   preferredDefaultDeviceName, preferredSetupOptions);

        createEditorComp();

        if (PropertySet* props = pluginHolder->settings)
        {
            const int x = props->getIntValue ("windowX", -100);
            const int y = props->getIntValue ("windowY", -100);

            if (x != -100 && y != -100)
                setBoundsConstrained (juce::Rectangle<int> (x, y, getWidth(), getHeight()));
            else
                centreWithSize (getWidth(), getHeight());
        }
        else
        {
            centreWithSize (getWidth(), getHeight());
        }
    }

    ~StandaloneFilterWindow()
    {
        if (PropertySet* props = pluginHolder->settings)
        {
            props->setValue ("windowX", getX());
            props->setValue ("windowY", getY());
        }

        pluginHolder->stopPlaying();
        deleteEditorComp();
        pluginHolder = nullptr;
    }

    //==============================================================================
    AudioProcessor* getAudioProcessor() const noexcept      { return pluginHolder->processor; }
    AudioDeviceManager& getDeviceManager() const noexcept   { return pluginHolder->deviceManager; }

    void createEditorComp()
    {
        setContentOwned (getAudioProcessor()->createEditorIfNeeded(), true);
    }

    void deleteEditorComp()
    {
        if (AudioProcessorEditor* ed = dynamic_cast<AudioProcessorEditor*> (getContentComponent()))
        {
            pluginHolder->processor->editorBeingDeleted (ed);
            clearContentComponent();
        }
    }

    /** Deletes and re-creates the plugin, resetting it to its default state. */
    void resetToDefaultState()
    {
        pluginHolder->stopPlaying();
        deleteEditorComp();
        pluginHolder->deletePlugin();

        if (PropertySet* props = pluginHolder->settings)
            props->removeValue ("filterState");

        pluginHolder->createPlugin();
        createEditorComp();
        pluginHolder->startPlaying();
    }

    //==============================================================================
    void closeButtonPressed() override
    {
        JUCEApplicationBase::quit();
    }

    void buttonClicked (Button*) override
    {
        PopupMenu m;
        m.addItem (1, TRANS("Audio Settings..."));
        m.addSeparator();
        m.addItem (2, TRANS("Save current state..."));
        m.addItem (3, TRANS("Load a saved state..."));
        m.addSeparator();
        m.addItem (4, TRANS("Reset to default state"));

        m.showMenuAsync (PopupMenu::Options(),
                         ModalCallbackFunction::forComponent (menuCallback, this));
    }

    void handleMenuResult (int result)
    {
        switch (result)
        {
            case 1:  pluginHolder->showAudioSettingsDialog(); break;
            case 2:  pluginHolder->askUserToSaveState(); break;
            case 3:  pluginHolder->askUserToLoadState(); break;
            case 4:  resetToDefaultState(); break;
            default: break;
        }
    }

    static void menuCallback (int result, StandaloneFilterWindow* button)
    {
        if (button != nullptr && result != 0)
            button->handleMenuResult (result);
    }

    void resized() override
    {
        DocumentWindow::resized();
        optionsButton.setBounds (8, 6, 60, getTitleBarHeight() - 8);
    }

    ScopedPointer<StandalonePluginHolder> pluginHolder;

private:
    //==============================================================================
    TextButton optionsButton;

    JUCE_DECLARE_NON_COPYABLE_WITH_LEAK_DETECTOR (StandaloneFilterWindow)
};


#endif   // JUCE_STANDALONEFILTERWINDOW_H_INCLUDED
