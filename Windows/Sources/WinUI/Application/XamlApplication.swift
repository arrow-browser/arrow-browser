// Adapted from The Browser Company's swift-winui (SwiftApplication.swift,
// BSD-3-Clause).
import WinAppSDK
@_spi(WinRTImplements) import WindowsFoundation

/// A WinUI application written in Swift. Without XAML compilation, the app
/// provides the XAML type metadata itself: that of WinUI's controls, which
/// their styles need.
open class XamlApplication: Application, IXamlMetadataProvider {
    public required override init() {
        super.init()
    }

    @_spi(WinRTImplements)
    override public func onLaunched(_ args: LaunchActivatedEventArgs?) {
        resources.mergedDictionaries.append(XamlControlsResources())
        launched()
    }

    /// Called once the application has started: create the first window here.
    open func launched() {}

    override open func queryInterface(_ iid: WindowsFoundation.IID) -> IUnknownRef? {
        switch iid {
        case __ABI_Microsoft_UI_Xaml_Markup.IXamlMetadataProviderWrapper.IID:
            __ABI_Microsoft_UI_Xaml_Markup.IXamlMetadataProviderWrapper(self)?.queryInterface(iid)
        default:
            super.queryInterface(iid)
        }
    }

    private lazy var metadataProvider = XamlControlsXamlMetaDataProvider()

    public func getXamlType(_ type: TypeName) throws -> IXamlType! {
        try metadataProvider.getXamlType(type)
    }

    public func getXamlType(_ fullName: String) throws -> IXamlType! {
        try metadataProvider.getXamlType(fullName)
    }

    public func getXmlnsDefinitions() throws -> [XmlnsDefinition] {
        try metadataProvider.getXmlnsDefinitions()
    }
}
