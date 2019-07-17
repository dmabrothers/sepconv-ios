//
//  SepConvNetwork.swift
//  SepConv-iOS
//
//  Created by Carlo Rapisarda on 2019-07-11.
//  Copyright © 2019 Carlo Rapisarda. All rights reserved.
//

import MetalKit
import CoreML


// MARK: SepConvNetwork

enum SepConvError: Error {
    case modelNotConfigured
    case sepConvNotConfigured
    case sepConvFailed
    case imageConversionFailed
    case cannotAllocateVideoMemory
}

class SepConvNetwork {
    
    private let partialNetwork: SepConvPartialNetwork512
    private let separableConvolution: SeparableConvolution
    
    private var filterLength: Int {
        return partialNetwork.filterLength
    }
    
    private var networkInputSide: Int {
        return partialNetwork.inputSide
    }
    
    private var imageDepth: Int {
        return partialNetwork.imageDepth
    }
    
    private var maxImageSide: Int {
        return networkInputSide - filterLength
    }
    
    init() {
        partialNetwork = .init()
        separableConvolution = SeparableConvolution(
            filterLength: partialNetwork.filterLength,
            networkInputSide: partialNetwork.inputSide,
            imageDepth: partialNetwork.imageDepth
        )
    }
    
    func prepare() throws {
        try separableConvolution.prepareForMetal()
    }
    
    private func computePadding(for input: MLMultiArray) -> SepConvPadding {
        
        let height = input.shape[3].intValue
        let width = input.shape[4].intValue
        
        if height == networkInputSide && width == networkInputSide {
            return .zero
        }
        
        let heightPad = max(networkInputSide - height, 0)
        let widthPad = max(networkInputSide - width, 0)
        
        let left = widthPad / 2
        let top = heightPad / 2
        let right = widthPad - left
        let bottom = heightPad - top
        
        return SepConvPadding(left: left, right: right, top: top, bottom: bottom)
    }
    
    private func resizeImageIfNeeded(_ image: CGImage) -> CGImage? {
        let maxSide = max(image.width, image.height)
        if maxSide <= maxImageSide {
            return image
        }
        return image.resized(withMaxSide: maxImageSide)
    }
    
    private func forward(input: MLMultiArray) throws -> MLMultiArray {
        
        precondition(input.shape.count == 5)
        precondition(input.shape[0].intValue == 1)
        precondition(input.shape[1].intValue == 1)
        precondition(input.shape[2].intValue == imageDepth * 2)
        precondition(input.shape[3].intValue <= networkInputSide)
        precondition(input.shape[4].intValue <= networkInputSide)
        
        let padding = computePadding(for: input)
        let paddedInput: MLMultiArray
        if padding.isNonZero {
            paddedInput = input.replicationPad2D(padding)
        } else {
            paddedInput = input
        }
        
        let partialOutput = try partialNetwork.prediction(input_frames: paddedInput)
        
        let output1 = try separableConvolution.forward(
            input: partialOutput.padded_i1,
            vertical: partialOutput.k1v,
            horizontal: partialOutput.k1h
        )
        
        let output2 = try separableConvolution.forward(
            input: partialOutput.padded_i2,
            vertical: partialOutput.k2v,
            horizontal: partialOutput.k2h
        )
        
        let output = add(output1, output2)
        
        let trimmedOutput: MLMultiArray
        if padding.isNonZero {
            trimmedOutput = output.trim2D(padding)
        } else {
            trimmedOutput = output
        }
        
        return trimmedOutput
    }
    
    func preprocess(frame: CGImage) throws -> CGImage {
        guard let resized = resizeImageIfNeeded(frame),
            let rgba = convertImageByteOrderIfNeeded(resized) else {
                throw SepConvError.imageConversionFailed
        }
        return rgba
    }
    
    func interpolate(frameA: MLMultiArray, frameB: MLMultiArray) throws -> MLMultiArray {
        
        precondition(frameA.dataType == .float32 && frameB.dataType == .float32)
        precondition(frameA.shape == frameB.shape && frameA.shape.count == 5)
        precondition(frameA.shape[0].intValue == 1 && frameA.shape[1].intValue == 1)
        precondition(frameA.shape[2].intValue == imageDepth)
        precondition(frameA.shape[3].intValue <= maxImageSide)
        precondition(frameA.shape[4].intValue <= maxImageSide)
        
        let input = stack(frameA, frameB)
        return try forward(input: input)
    }
    
    func interpolate(frameA: CGImage, frameB: CGImage) throws -> CGImage {
        
        let frameA = try preprocess(frame: frameA)
        let frameB = try preprocess(frame: frameB)
        
        guard let arrayA = MLMultiArray.fromImage(frameA),
              let arrayB = MLMultiArray.fromImage(frameB) else {
            throw SepConvError.imageConversionFailed
        }
        
        let res = try interpolate(frameA: arrayA, frameB: arrayB)
        if let resImage = res.toCGImage() {
            return resImage
        } else {
            throw SepConvError.imageConversionFailed
        }
    }
    
    func interpolate(frameA: UIImage, frameB: UIImage) throws -> UIImage {
        guard let frameA = frameA.cgImage,
              let frameB = frameB.cgImage else {
            throw SepConvError.imageConversionFailed
        }
        let res = try interpolate(frameA: frameA, frameB: frameB)
        return UIImage(cgImage: res)
    }
}


// MARK: - SepConvPartialNetwork Protocol

protocol SepConvPartialNetwork {
    var inputShape: [NSNumber] { get }
    var filterLength: Int { get }
    var inputSide: Int { get }
    var imageDepth: Int { get }
    var model: MLModel { get }
}

extension SepConvPartialNetwork {
    
    var inputShape: [NSNumber] {
        let inputDescription = model.modelDescription.inputDescriptionsByName["input_frames"]!
        return [1, 1] + inputDescription.multiArrayConstraint!.shape
    }
    
    var filterLength: Int {
        return 51
    }
    
    var inputSide: Int {
        return inputShape[3].intValue
    }
    
    var imageDepth: Int {
        return inputShape[2].intValue / 2
    }
}

extension SepConvPartialNetwork128: SepConvPartialNetwork {}
extension SepConvPartialNetwork256: SepConvPartialNetwork {}
extension SepConvPartialNetwork512: SepConvPartialNetwork {}
extension SepConvPartialNetwork1024: SepConvPartialNetwork {}


// MARK: - Input Padding

private struct SepConvPadding {
    let left: Int
    let right: Int
    let top: Int
    let bottom: Int
    
    static var zero: SepConvPadding {
        return SepConvPadding(left: 0, right: 0, top: 0, bottom: 0)
    }
    
    var isNonZero: Bool {
        return left != 0 || right != 0 || top != 0 || bottom != 0
    }
}

private extension MLMultiArray {
    
    func trim2D(_ p: SepConvPadding) -> MLMultiArray {
        return trim2D(left: p.left, right: p.right, top: p.top, bottom: p.bottom)
    }
    
    func replicationPad2D(_ p: SepConvPadding) -> MLMultiArray {
        return replicationPad2D(left: p.left, right: p.right, top: p.top, bottom: p.bottom)
    }
}


// MARK: - Utilities

private func convertImageByteOrderIfNeeded(_ image: CGImage) -> CGImage? {
    if image.bytesPerRow != image.width * (image.bitsPerPixel / 8) {
        return image.toRGBA()
    }
    return image
}
