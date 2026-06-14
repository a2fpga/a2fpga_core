#!/bin/sh

# Based on https://github.com/charlie-mtz/gowin-eda-mac-fixer
# Fixed by u/solustaeda on Reddit r/GowinFGPA
# NOTES 09-07-25:
# Updated for Gowin_V1.9.12_macOS
# i.e. just commented out stuff that's no longer applicable
# warning: other functionality may not work
# 
# USAGE:
# 1) Make sure the script has execute permissions:
#    chmod +x gowin_eda_mac_fixer.sh
# 2) Extract Gowin_V1.9.12_macOS.dmg -> GowinIDE to the same directory as the script
# 3) Run the script:
#    ./gowin_eda_mac_fixer.sh GowinIDE.app
# 4) Enter your password to remove the quarantine
#    - There are a few errors, but they seem harmless
# 5) Copy GowinIDE.app to whereever it's going to live
# 6) Launch GowinIDE and license it
#    - For licensing tips, see https://nand2mario.github.io/posts/2024/tang_tips/
# 7) Be sure to add /Applications/GowinIDE.app/Contents/Resources/Gowin_EDA/IDE/bin
#    (or wherever you decided it will live)
# 8) It seems there has to be another instance of gw_sh running in another terminal window 
#    first in order to be able to launch it from a script without the licensing complaining 

#GOWIN_EDA_ARCHIVE="$PWD/$1"
GOWIN_EDA_DIR="$PWD/GowinIDE.app/Contents/Resources/Gowin_EDA"
GOWIN_EDA_APP="$PWD/GowinIDE.app"
#GOWIN_EDA_APP_BUNDLE="GowinIDE"
#SCRATCHPAD_DIR=$(uuidgen)

#mkdir $SCRATCHPAD_DIR
#cd $SCRATCHPAD_DIR

### Unpack ##
#/bin/echo -n "Unpacking..."
#rm -rf $GOWIN_EDA_DIR
#mkdir $GOWIN_EDA_DIR
#tar -xzf $GOWIN_EDA_ARCHIVE -C $GOWIN_EDA_DIR
#/bin/echo "Done"

### Remove quarantine ###
/bin/echo "We are about to remove the quarantine from the unpacked files. For this you will need to enter your password."
sudo xattr -cr $GOWIN_EDA_APP

### Fix linking issues ###
/bin/echo -n "Fixing linking issues..."

# Add RPATH to local lib directory relative to the executable path
install_name_tool -add_rpath @executable_path/../lib $GOWIN_EDA_DIR/IDE/bin/gw_ide
install_name_tool -delete_rpath '$ORIGIN:$ORIGIN/../lib' $GOWIN_EDA_DIR/IDE/bin/gw_ide
install_name_tool -add_rpath @executable_path/../lib $GOWIN_EDA_DIR/IDE/bin/GowinSynthesis
install_name_tool -delete_rpath '$ORIGIN:$ORIGIN/../lib' $GOWIN_EDA_DIR/IDE/bin/GowinSynthesis
install_name_tool -add_rpath @executable_path/../lib $GOWIN_EDA_DIR/IDE/bin/floorplanner
install_name_tool -delete_rpath '$ORIGIN:$ORIGIN/../lib' $GOWIN_EDA_DIR/IDE/bin/floorplanner
install_name_tool -add_rpath @executable_path/../lib $GOWIN_EDA_DIR/IDE/bin/gao_analyzer
install_name_tool -delete_rpath '$ORIGIN:$ORIGIN/../lib' $GOWIN_EDA_DIR/IDE/bin/gao_analyzer
install_name_tool -add_rpath @executable_path/../lib $GOWIN_EDA_DIR/IDE/bin/gao_sh
install_name_tool -delete_rpath '$ORIGIN:$ORIGIN/../lib' $GOWIN_EDA_DIR/IDE/bin/gao_sh
install_name_tool -add_rpath @executable_path/../lib $GOWIN_EDA_DIR/IDE/bin/gvio_analyzer
install_name_tool -delete_rpath '$ORIGIN:$ORIGIN/../lib' $GOWIN_EDA_DIR/IDE/bin/gvio_analyzer
install_name_tool -add_rpath @executable_path/../lib $GOWIN_EDA_DIR/IDE/bin/gvio_sh
install_name_tool -delete_rpath '$ORIGIN:$ORIGIN/../lib' $GOWIN_EDA_DIR/IDE/bin/gvio_sh
install_name_tool -add_rpath @executable_path/../lib $GOWIN_EDA_DIR/IDE/bin/gw_ctrl_reg
install_name_tool -delete_rpath '$ORIGIN:$ORIGIN/../lib' $GOWIN_EDA_DIR/IDE/bin/gw_ctrl_reg
install_name_tool -add_rpath @executable_path/../lib $GOWIN_EDA_DIR/IDE/bin/gw_fsrst_gui
install_name_tool -delete_rpath '$ORIGIN:$ORIGIN/../lib' $GOWIN_EDA_DIR/IDE/bin/gw_fsrst_gui
install_name_tool -add_rpath @executable_path/../lib $GOWIN_EDA_DIR/IDE/bin/gw_pkgviewer
install_name_tool -delete_rpath '$ORIGIN:$ORIGIN/../lib' $GOWIN_EDA_DIR/IDE/bin/gw_pkgviewer
install_name_tool -add_rpath @executable_path/../lib $GOWIN_EDA_DIR/IDE/bin/gw_sdceditor
install_name_tool -delete_rpath '$ORIGIN:$ORIGIN/../lib' $GOWIN_EDA_DIR/IDE/bin/gw_sdceditor
install_name_tool -add_rpath @executable_path/../lib $GOWIN_EDA_DIR/IDE/bin/gw_sh
install_name_tool -delete_rpath '$ORIGIN:$ORIGIN/../lib' $GOWIN_EDA_DIR/IDE/bin/gw_sh
install_name_tool -add_rpath @executable_path/../lib $GOWIN_EDA_DIR/IDE/bin/hierarchy
install_name_tool -delete_rpath '$ORIGIN:$ORIGIN/../lib' $GOWIN_EDA_DIR/IDE/bin/hierarchy
install_name_tool -add_rpath @executable_path/../lib $GOWIN_EDA_DIR/IDE/bin/nlsresource
install_name_tool -delete_rpath '$ORIGIN:$ORIGIN/../lib' $GOWIN_EDA_DIR/IDE/bin/nlsresource
install_name_tool -add_rpath @executable_path/../lib $GOWIN_EDA_DIR/IDE/bin/rtlHierTest
install_name_tool -delete_rpath '$ORIGIN:$ORIGIN/../lib' $GOWIN_EDA_DIR/IDE/bin/rtlHierTest
install_name_tool -add_rpath @executable_path/../lib $GOWIN_EDA_DIR/IDE/bin/vlg_pp
install_name_tool -delete_rpath '$ORIGIN:$ORIGIN/../lib' $GOWIN_EDA_DIR/IDE/bin/vlg_pp
install_name_tool -add_rpath '@executable_path/../lib' $GOWIN_EDA_DIR/IDE/bin/Assistant
install_name_tool -delete_rpath '@executable_path/../Frameworks' $GOWIN_EDA_DIR/IDE/bin/Assistant
install_name_tool -delete_rpath '@loader_path/../../../../lib' $GOWIN_EDA_DIR/IDE/bin/Assistant

# Ad-hoc codesign Assistant binary
codesign -s - -f $GOWIN_EDA_DIR/IDE/bin/Assistant

# Fix Tcl framework references to built-in version instead of system version
install_name_tool -change /Library/Frameworks/Tcl.framework/Versions/8.6/Tcl @rpath/Tcl.framework/Versions/8.6/Tcl $GOWIN_EDA_DIR/IDE/bin/GowinModgen
install_name_tool -change /Library/Frameworks/Tcl.framework/Versions/8.6/Tcl @rpath/Tcl.framework/Versions/8.6/Tcl $GOWIN_EDA_DIR/IDE/bin/GowinSynthesis
install_name_tool -change /Library/Frameworks/Tcl.framework/Versions/8.6/Tcl @rpath/Tcl.framework/Versions/8.6/Tcl $GOWIN_EDA_DIR/IDE/bin/gw_sdceditor
install_name_tool -change /Library/Frameworks/Tcl.framework/Versions/8.6/Tcl @rpath/Tcl.framework/Versions/8.6/Tcl $GOWIN_EDA_DIR/IDE/bin/gw_sh
install_name_tool -change /Library/Frameworks/Tcl.framework/Versions/8.6/Tcl @rpath/Tcl.framework/Versions/8.6/Tcl $GOWIN_EDA_DIR/IDE/bin/hierarchy
install_name_tool -change /Library/Frameworks/Tcl.framework/Versions/8.6/Tcl @rpath/Tcl.framework/Versions/8.6/Tcl $GOWIN_EDA_DIR/IDE/bin/nlsresource
install_name_tool -change /Library/Frameworks/Tcl.framework/Versions/8.6/Tcl @rpath/Tcl.framework/Versions/8.6/Tcl $GOWIN_EDA_DIR/IDE/bin/rtlHierTest
install_name_tool -change /Library/Frameworks/Tcl.framework/Versions/8.6/Tcl @rpath/Tcl.framework/Versions/8.6/Tcl $GOWIN_EDA_DIR/IDE/bin/vlg_pp
install_name_tool -change /Library/Frameworks/Tcl.framework/Versions/8.6/Tcl @rpath/Tcl.framework/Versions/8.6/Tcl $GOWIN_EDA_DIR/IDE/plugins/ide/libGAOIns.dylib
install_name_tool -change /Library/Frameworks/Tcl.framework/Versions/8.6/Tcl @rpath/Tcl.framework/Versions/8.6/Tcl $GOWIN_EDA_DIR/IDE/plugins/ide/libRtlGAOIns.dylib
install_name_tool -change /Library/Frameworks/Tcl.framework/Versions/8.6/Tcl @rpath/Tcl.framework/Versions/8.6/Tcl $GOWIN_EDA_DIR/IDE/plugins/ide/libGPC.dylib
install_name_tool -change /Library/Frameworks/Tcl.framework/Versions/8.6/Tcl @rpath/Tcl.framework/Versions/8.6/Tcl $GOWIN_EDA_DIR/IDE/plugins/ide/libGVIO.dylib
install_name_tool -change /Library/Frameworks/Tcl.framework/Versions/8.6/Tcl @rpath/Tcl.framework/Versions/8.6/Tcl $GOWIN_EDA_DIR/IDE/plugins/ide/libTextEditor.dylib
install_name_tool -change /Library/Frameworks/Tcl.framework/Versions/8.6/Tcl @rpath/Tcl.framework/Versions/8.6/Tcl $GOWIN_EDA_DIR/IDE/plugins/ide/libCoreGen.dylib
install_name_tool -change /Library/Frameworks/Tcl.framework/Versions/8.6/Tcl @rpath/Tcl.framework/Versions/8.6/Tcl $GOWIN_EDA_DIR/IDE/plugins/ide/libFpgaPrj.dylib
install_name_tool -change /Library/Frameworks/Tcl.framework/Versions/8.6/Tcl @rpath/Tcl.framework/Versions/8.6/Tcl $GOWIN_EDA_DIR/IDE/lib/libhdlresolve.dylib
install_name_tool -change /Library/Frameworks/Tcl.framework/Versions/8.6/Tcl @rpath/Tcl.framework/Versions/8.6/Tcl $GOWIN_EDA_DIR/IDE/lib/libNlsUtils.dylib
install_name_tool -change /Library/Frameworks/Tcl.framework/Versions/8.6/Tcl @rpath/Tcl.framework/Versions/8.6/Tcl $GOWIN_EDA_DIR/IDE/lib/libNlsData.dylib
install_name_tool -change /Library/Frameworks/Tcl.framework/Versions/8.6/Tcl @rpath/Tcl.framework/Versions/8.6/Tcl $GOWIN_EDA_DIR/IDE/lib/libGWTE.dylib
install_name_tool -change /Library/Frameworks/Tcl.framework/Versions/8.6/Tcl @rpath/Tcl.framework/Versions/8.6/Tcl $GOWIN_EDA_DIR/IDE/lib/libgwsyn.dylib
install_name_tool -change /Library/Frameworks/Tcl.framework/Versions/8.6/Tcl @rpath/Tcl.framework/Versions/8.6/Tcl $GOWIN_EDA_DIR/IDE/lib/libNlsUtils.dylib
install_name_tool -change /Library/Frameworks/Tcl.framework/Versions/8.6/Tcl @rpath/Tcl.framework/Versions/8.6/Tcl $GOWIN_EDA_DIR/IDE/lib/libnetcatcher.dylib
install_name_tool -change /Library/Frameworks/Tcl.framework/Versions/8.6/Tcl @rpath/Tcl.framework/Versions/8.6/Tcl $GOWIN_EDA_DIR/IDE/lib/libNlsData.dylib
install_name_tool -change /Library/Frameworks/Tcl.framework/Versions/8.6/Tcl @rpath/Tcl.framework/Versions/8.6/Tcl $GOWIN_EDA_DIR/IDE/lib/librtlhierarchy.dylib
install_name_tool -change /Library/Frameworks/Tcl.framework/Versions/8.6/Tcl @rpath/Tcl.framework/Versions/8.6/Tcl $GOWIN_EDA_DIR/IDE/lib/librtlparser.dylib
install_name_tool -change /Library/Frameworks/Tcl.framework/Versions/8.6/Tcl @rpath/Tcl.framework/Versions/8.6/Tcl $GOWIN_EDA_DIR/IDE/lib/librtlviewer.dylib

# Fix libcrypto references to built-in version instead of system version
install_name_tool -change /opt/homebrew/opt/openssl@3/lib/libcrypto.3.dylib @rpath/libcrypto.3.dylib $GOWIN_EDA_DIR/IDE/bin/gw_ide
install_name_tool -change /opt/homebrew/opt/openssl@3/lib/libcrypto.3.dylib @rpath/libcrypto.3.dylib $GOWIN_EDA_DIR/IDE/bin/GowinModgen
install_name_tool -change /opt/homebrew/opt/openssl@3/lib/libcrypto.3.dylib @rpath/libcrypto.3.dylib $GOWIN_EDA_DIR/IDE/bin/GowinSynthesis
install_name_tool -change /opt/homebrew/opt/openssl@3/lib/libcrypto.3.dylib @rpath/libcrypto.3.dylib $GOWIN_EDA_DIR/IDE/bin/gw_sdceditor
install_name_tool -change /opt/homebrew/opt/openssl@3/lib/libcrypto.3.dylib @rpath/libcrypto.3.dylib $GOWIN_EDA_DIR/IDE/bin/gw_sh
install_name_tool -change /opt/homebrew/opt/openssl@3/lib/libcrypto.3.dylib @rpath/libcrypto.3.dylib $GOWIN_EDA_DIR/IDE/bin/hierarchy
install_name_tool -change /opt/homebrew/opt/openssl@3/lib/libcrypto.3.dylib @rpath/libcrypto.3.dylib $GOWIN_EDA_DIR/IDE/bin/license_config_gui
install_name_tool -change /opt/homebrew/opt/openssl@3/lib/libcrypto.3.dylib @rpath/libcrypto.3.dylib $GOWIN_EDA_DIR/IDE/bin/nlsresource
install_name_tool -change /opt/homebrew/opt/openssl@3/lib/libcrypto.3.dylib @rpath/libcrypto.3.dylib $GOWIN_EDA_DIR/IDE/bin/rtlHierTest
install_name_tool -change /opt/homebrew/opt/openssl@3/lib/libcrypto.3.dylib @rpath/libcrypto.3.dylib $GOWIN_EDA_DIR/IDE/bin/vlg_pp
install_name_tool -change /opt/homebrew/opt/openssl@3/lib/libcrypto.3.dylib @rpath/libcrypto.3.dylib $GOWIN_EDA_DIR/IDE/lib/libgowin.dylib
install_name_tool -change /opt/homebrew/opt/openssl@3/lib/libcrypto.3.dylib @rpath/libcrypto.3.dylib $GOWIN_EDA_DIR/IDE/lib/libgwsyn.dylib
install_name_tool -change /opt/homebrew/opt/openssl@3/lib/libcrypto.3.dylib @rpath/libcrypto.3.dylib $GOWIN_EDA_DIR/IDE/lib/libNlsData.dylib
install_name_tool -change /opt/homebrew/opt/openssl@3/lib/libcrypto.3.dylib @rpath/libcrypto.3.dylib $GOWIN_EDA_DIR/IDE/lib/libNlsUtils.dylib
install_name_tool -change /opt/homebrew/opt/openssl@3/lib/libcrypto.3.dylib @rpath/libcrypto.3.dylib $GOWIN_EDA_DIR/IDE/lib/libGWTE.dylib
install_name_tool -change /opt/homebrew/opt/openssl@3/lib/libcrypto.3.dylib @rpath/libcrypto.3.dylib $GOWIN_EDA_DIR/IDE/lib/libGowinProxy.dylib
# install_name_tool -change /opt/homebrew/opt/openssl@3/lib/libcrypto.3.dylib @rpath/libcrypto.3.dylib $GOWIN_EDA_DIR/IDE/lib/libcrypto.3.dylib
install_name_tool -change /opt/homebrew/opt/openssl@3/lib/libcrypto.3.dylib @rpath/libcrypto.3.dylib $GOWIN_EDA_DIR/IDE/lib/libhdlresolve.dylib
install_name_tool -change /opt/homebrew/opt/openssl@3/lib/libcrypto.3.dylib @rpath/libcrypto.3.dylib $GOWIN_EDA_DIR/IDE/lib/libnetcatcher.dylib
install_name_tool -change /opt/homebrew/opt/openssl@3/lib/libcrypto.3.dylib @rpath/libcrypto.3.dylib $GOWIN_EDA_DIR/IDE/lib/librtlhierarchy.dylib
install_name_tool -change /opt/homebrew/opt/openssl@3/lib/libcrypto.3.dylib @rpath/libcrypto.3.dylib $GOWIN_EDA_DIR/IDE/lib/librtlparser.dylib
install_name_tool -change /opt/homebrew/opt/openssl@3/lib/libcrypto.3.dylib @rpath/libcrypto.3.dylib $GOWIN_EDA_DIR/IDE/lib/librtlviewer.dylib
install_name_tool -change /opt/homebrew/opt/openssl@3/lib/libcrypto.3.dylib @rpath/libcrypto.3.dylib $GOWIN_EDA_DIR/IDE/plugins/ide/libCoreGen.dylib
install_name_tool -change /opt/homebrew/opt/openssl@3/lib/libcrypto.3.dylib @rpath/libcrypto.3.dylib $GOWIN_EDA_DIR/IDE/plugins/ide/libFpgaPrj.dylib
install_name_tool -change /opt/homebrew/opt/openssl@3/lib/libcrypto.3.dylib @rpath/libcrypto.3.dylib $GOWIN_EDA_DIR/IDE/plugins/ide/libGAOIns.dylib
install_name_tool -change /opt/homebrew/opt/openssl@3/lib/libcrypto.3.dylib @rpath/libcrypto.3.dylib $GOWIN_EDA_DIR/IDE/plugins/ide/libGPC.dylib
install_name_tool -change /opt/homebrew/opt/openssl@3/lib/libcrypto.3.dylib @rpath/libcrypto.3.dylib $GOWIN_EDA_DIR/IDE/plugins/ide/libGVIO.dylib
install_name_tool -change /opt/homebrew/opt/openssl@3/lib/libcrypto.3.dylib @rpath/libcrypto.3.dylib $GOWIN_EDA_DIR/IDE/plugins/ide/libRtlGAOIns.dylib
install_name_tool -change /opt/homebrew/opt/openssl@3/lib/libcrypto.3.dylib @rpath/libcrypto.3.dylib $GOWIN_EDA_DIR/IDE/plugins/ide/libTextEditor.dylib

/bin/echo "Done"


### Create App Bundle ###
#/bin/echo -n "Creating App Bundle..."

#mkdir "$GOWIN_EDA_APP_BUNDLE.app"
#mkdir "$GOWIN_EDA_APP_BUNDLE.app/Contents"
#mkdir "$GOWIN_EDA_APP_BUNDLE.app/Contents/Resources"
#mkdir "$GOWIN_EDA_APP_BUNDLE.app/Contents/MacOS"

# Create Info.plist
#/bin/echo '<?xml version="1.0" encoding="UTF-8"?>
#<!DOCTYPE plist PUBLIC "-//Apple Computer//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
#<plist version="1.0">
#<dict>
#  <key>CFBundleName</key>
#  <string>GowinEDA</string>
#  <key>CFBundleExecutable</key>
#  <string>starter</string>
#  <key>CFBundleIdentifier</key>
#  <string>com.gowinsemi.gowineda</string>
#  <key>CFBundleVersion</key>
#  <string>1.0.0</string>
#  <key>CFBundleIconFile</key>
#  <string>icon.icns</string>
#</dict>
#</plist>' > "$GOWIN_EDA_APP_BUNDLE.app/Contents/Info.plist"

# Create starter script
#/bin/echo '#!/bin/sh

#GOWIN_EDA_BIN_DIR="$(dirname "$0")"/../Resources/Gowin_EDA/IDE/bin

#cd $GOWIN_EDA_BIN_DIR
#./gw_ide' > "$GOWIN_EDA_APP_BUNDLE.app/Contents/MacOS/starter"

# Mark starter script as executable
#chmod +x "$GOWIN_EDA_APP_BUNDLE.app/Contents/MacOS/starter"

# Place Gowin icon
#

# Move processed Gowin EDA directory to App Bundle
#mv $GOWIN_EDA_DIR "$GOWIN_EDA_APP_BUNDLE.app/Contents/Resources/"

/bin/echo "Done"

### Move App Bundle outside the scratchpad directory
#mv "$GOWIN_EDA_APP_BUNDLE.app" ../

### Cleanup ###
#cd ..
#rm -rf $SCRATCHPAD_DIR