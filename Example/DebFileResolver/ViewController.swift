//
//  ViewController.swift
//  DylibExtract
//
//  Created by hy on 2023/11/7.
//

import UIKit
import UniformTypeIdentifiers

class ViewController: UIViewController, UIDocumentPickerDelegate {
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        let button = UIButton(type: .custom)
        button.setTitle("select a deb file", for: .normal)
        button.frame = CGRect(x: 40, y: 100, width: view.bounds.width - 80, height: 60)
        button.backgroundColor = UIColor.orange
        button.titleLabel?.textColor = UIColor.white
        button.addTarget(self, action: #selector(goFileApp), for: .touchUpInside)
        view.addSubview(button)
        
    }
    
    @objc func goFileApp() {
        var documentCtr: UIDocumentPickerViewController?
        if #available(iOS 14, *) {
            documentCtr = UIDocumentPickerViewController(forOpeningContentTypes: [
                UTType.item,
                UTType.content,
                UTType.compositeContent,
                UTType.diskImage,
                UTType.data,
                UTType.database,
                UTType.calendarEvent,
                UTType.message,
                UTType.presentation,
                UTType.contact,
                UTType.archive,
                UTType.text,
                UTType.image
            ], asCopy: true)
        } else {
            documentCtr = UIDocumentPickerViewController(documentTypes: [
                "public.item",
                "public.content",
                "public.composite-content",
                "public.disk-image",
                "public.data",
                "public.database",
                "public.calendar-event",
                "public.message",
                "public.presentation",
                "public.contact",
                "public.archive",
                "public.text",
                "public.image"
            ], in: .import)
        }
        documentCtr!.delegate = self
        documentCtr!.modalPresentationStyle = .fullScreen
        present(documentCtr!, animated: true)
    }
    
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        if (urls.count > 0) {
            let absoluteString = urls.first!.absoluteString
            let fileUrlPrefix = "file://"
            
            let doit = { (success: Bool, dylibs: ([String]?)) in
                if (success) {
                    print(dylibs!);
                }else{
                    // failed

                }
            }
            
            if (absoluteString.hasPrefix(fileUrlPrefix)) {
                let index = absoluteString.index(absoluteString.startIndex, offsetBy: fileUrlPrefix.count)
                let subString = absoluteString[index...]
                print("filePath:",subString)
                DebFileResolverWrapper.decompressDeb(filePath: String(subString), completion: doit)
            }else{
                DebFileResolverWrapper.decompressDeb(filePath: absoluteString , completion: doit)
            }
        }
    }
}

