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

#ifndef JUCE_VST3PLUGINFORMAT_H_INCLUDED
#define JUCE_VST3PLUGINFORMAT_H_INCLUDED

#if (JUCE_PLUGINHOST_VST3 && (JUCE_MAC || JUCE_WINDOWS)) || DOXYGEN

/**
    Implements a plugin format for VST3s.
*/
class JUCE_API VST3PluginFormat   : public AudioPluginFormat
{
public:
    /** Constructor */
    VST3PluginFormat();

    /** Destructor */
    ~VST3PluginFormat();

    //==============================================================================
    String getName() const override             { return "VST3"; }
    void findAllTypesForFile (OwnedArray<PluginDescription>&, const String& fileOrIdentifier) override;
    bool fileMightContainThisPluginType (const String& fileOrIdentifier) override;
    String getNameOfPluginFromIdentifier (const String& fileOrIdentifier) override;
    bool pluginNeedsRescanning (const PluginDescription&) override;
    StringArray searchPathsForPlugins (const FileSearchPath&, bool recursive, bool) override;
    bool doesPluginStillExist (const PluginDescription&) override;
    FileSearchPath getDefaultLocationsToSearch() override;
    bool canScanForPlugins() const override     { return true; }

private:
    void createPluginInstance (const PluginDescription&, double initialSampleRate,
                               int initialBufferSize, void* userData,
                               void (*callback) (void*, AudioPluginInstance*, const String&)) override;

    bool requiresUnblockedMessageThreadDuringCreation (const PluginDescription&) const noexcept override;

private:
    //==============================================================================
    void recursiveFileSearch (StringArray&, const File&, bool recursive);

    JUCE_DECLARE_NON_COPYABLE_WITH_LEAK_DETECTOR (VST3PluginFormat)
};

#endif   // JUCE_PLUGINHOST_VST3
#endif   // JUCE_VST3PLUGINFORMAT_H_INCLUDED
