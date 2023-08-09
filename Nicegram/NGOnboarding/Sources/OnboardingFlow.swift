import Foundation
import UIKit
import NGData
import NGPremiumUI
import NGStrings

public func onboardingController(languageCode: String, onComplete: @escaping () -> Void) -> UIViewController {
    let controller = OnboardingViewController(
        items: onboardingPages(languageCode: languageCode),
        languageCode: languageCode,
        onComplete: {
            if isPremium() {
                onComplete()
            } else if #available(iOS 13.0, *) {
                PremiumUITgHelper.routeToPremium(onComplete: onComplete)
            } else {
                onComplete()
            }
        }
    )
    
    return controller
}

private func onboardingPages(languageCode: String) -> [OnboardingPageViewModel] {
    (1...6).map { index in
        OnboardingPageViewModel(
            title: l("NicegramOnboarding.\(index).Title", languageCode),
            description: l("NicegramOnboarding.\(index).Desc", languageCode),
            videoURL: Bundle.main.url(forResource: "Nicegram_Onboarding-DS_v\(index)", withExtension: "mp4")!
        )
    }
}