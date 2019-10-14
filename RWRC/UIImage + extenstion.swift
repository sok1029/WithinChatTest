//
//  UIImage + extenstion.swift
//  RWRC
//
//  Created by SokJinYoung on 13/10/2019.
//  Copyright © 2019 Razeware. All rights reserved.
//

import Foundation
import UIKit

extension UIImage {

  static func storeImage(urlString: String, img: UIImage, quality: CGFloat = 1.0){
    let path = NSTemporaryDirectory().appending(UUID().uuidString)
    let url = URL(fileURLWithPath: path)
    
    let data = img.jpegData(compressionQuality: quality)
    try? data?.write(to: url)
    
    var dict = UserDefaults.standard.object(forKey: "ImageCache") as? [String:String]
    if dict == nil{
      dict = [String:String]()
    }
    dict![urlString] = path
    UserDefaults.standard.set(dict, forKey: "ImageCache")
    
  }

  static func loadImage(urlString: String) -> UIImage?{
    if let dict = UserDefaults.standard.object(forKey: "ImageCache") as? [String:String]{
      if let path = dict[urlString]{
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path)){
          let img = UIImage(data: data)
          return img
        }
      }
    }
    return nil
  }
  
  public convenience init?(color: UIColor, size: CGSize = CGSize(width: 1, height: 1)) {
    let rect = CGRect(origin: .zero, size: size)
    UIGraphicsBeginImageContextWithOptions(rect.size, false, 0.0)
    color.setFill()
    UIRectFill(rect)
    let image = UIGraphicsGetImageFromCurrentImageContext()
    UIGraphicsEndImageContext()

    guard let cgImage = image?.cgImage else { return nil }
    self.init(cgImage: cgImage)
}
}
