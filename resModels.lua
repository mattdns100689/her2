--  All rights reserved.
--
--  This source code is licensed under the BSD-style license found in the
--  LICENSE file in the root directory of this source tree. An additional grant
--  of patent rights can be found in the PATENTS file in the same directory.
--
--  The ResNet model definition
--

local nn = require 'nn'
require 'cunn'
layers = require "layers"

models = {}

local Convolution = nn.SpatialConvolution
local Avg = nn.SpatialAveragePooling
local ReLU = nn.ReLU
local Max = nn.SpatialMaxPooling
local SBatchNorm = nn.SpatialBatchNormalization

function models.resNet1()
	opt = {}
	opt.depth = 50 
	opt.shortcut = "C"
	opt.dataset = "her2"
	opt.shortcutType = "C"
   local depth = opt.depth
   local shortcutType = opt.shortcutType or 'B'
   local iChannels 

   -- The shortcut layer is either identity or 1x1 convolution
   local function shortcut(nInputPlane, nOutputPlane, stride)
      local useConv = shortcutType == 'C' or
         (shortcutType == 'B' and nInputPlane ~= nOutputPlane)
      if useConv then
         -- 1x1 convolution
         return nn.Sequential()
            :add(Convolution(nInputPlane, nOutputPlane, 1, 1, stride, stride))
            :add(SBatchNorm(nOutputPlane))
      elseif nInputPlane ~= nOutputPlane then
         -- Strided, zero-padded identity shortcut
         return nn.Sequential()
            :add(nn.SpatialAveragePooling(1, 1, stride, stride))
            :add(nn.Concat(2)
               :add(nn.Identity())
               :add(nn.MulConstant(0)))
      else
         return nn.Identity()
      end
   end

   -- The basic residual layer block for 18 and 34 layer network, and the
   -- CIFAR networks
   local function basicblock(n, stride)
      local nInputPlane = iChannels
      iChannels = n

      local s = nn.Sequential()
      s:add(Convolution(nInputPlane,n,3,3,stride,stride,1,1))
      s:add(SBatchNorm(n))
      s:add(ReLU(true))
      s:add(Convolution(n,n,3,3,1,1,1,1))
      s:add(SBatchNorm(n))

      return nn.Sequential()
         :add(nn.ConcatTable()
            :add(s)
            :add(shortcut(nInputPlane, n, stride)))
         :add(nn.CAddTable(true))
         :add(ReLU(true))
   end

   -- The bottleneck residual layer for 50, 101, and 152 layer networks
   local function bottleneck(n, stride)
      local nInputPlane = iChannels
      iChannels = n * 4

      local s = nn.Sequential()
      s:add(Convolution(nInputPlane,n,1,1,1,1,0,0))
      s:add(SBatchNorm(n))
      s:add(ReLU(true))
      s:add(Convolution(n,n,3,3,stride,stride,1,1))
      s:add(SBatchNorm(n))
      s:add(ReLU(true))
      s:add(Convolution(n,n*4,1,1,1,1,0,0))
      s:add(SBatchNorm(n * 4))

      return nn.Sequential()
         :add(nn.ConcatTable()
            :add(s)
            :add(shortcut(nInputPlane, n * 4, stride)))
         :add(nn.CAddTable(true))
         :add(ReLU(true))
   end

   -- Creates count residual blocks with specified number of features
   function layer(block, features, count, stride)
      local s = nn.Sequential()
      for i=1,count do
         s:add(block(features, i == 1 and stride or 1))
      end
      return s
   end

   local model = nn.Sequential()
	-- Configurations for ResNet:
	--  num. residual blocks, num features, residual block function
	local cfg = {
	 [18]  = {{2, 2, 2, 2}, 512, basicblock},
	 [34]  = {{3, 4, 6, 3}, 512, basicblock},
	 [50]  = {{3, 4, 6, 3}, 2048, bottleneck},
	 [101] = {{3, 4, 23, 3}, 2048, bottleneck},
	 [152] = {{3, 8, 36, 3}, 2048, bottleneck},
	}

	assert(cfg[depth], 'Invalid depth: ' .. tostring(depth))
	def, nFeatures, block = table.unpack(cfg[depth])
	iChannels = 16 

	-- The ResNet HER2 model
	model:add(Convolution(3,16,2,2,2,2,3,3))
	model:add(SBatchNorm(16))
	model:add(ReLU(true))
	model:add(Max(3,3,2,2,1,1))
	model:add(layer(block, 16, def[1], 2))
	model:add(layer(block, 16, def[2], 2))
	model:add(layer(block, 16, def[3], 2))
	model:add(Convolution(16*def[2],6,2,2,1,1,1,1))
	--model:add(layer(block, 16, def[4], 2))
	model:add(Avg(7, 7, 1, 1))
	--model:add(nn.View(nFeatures):setNumInputDims(3))
	--model:add(nn.Linear(nFeatures, 1))
	--
	local outputSize = model:forward(torch.randn(params.nWindows,3,params.windowSize,params.windowSize)):size()
	print("==>Output size before reshape")
	print(outputSize)
	local nOutputsDense = outputSize[2]*outputSize[3]*outputSize[4] 
	local feats = 50

	splitter = nn.ConcatTable()
	all,  oneByOne = nn.Sequential(),nn.Sequential()
	local function findAf(model) return model:add(nn.Sigmoid()) end

	-- All
	all:add(nn.View(nOutputsDense*params.nWindows))
	all:add(nn.Linear(nOutputsDense*params.nWindows,feats))
	layers.add_af(all)
	all:add(nn.Linear(feats,feats))
	layers.add_af(all)
	all:add(nn.Linear(feats,1))
	--findAf(oneByOne)

	-- One by one channel
	oneByOne:add(nn.View(nOutputsDense))
	--oneByOne:add(nn.BatchNormalization(nOutputsDense))
	oneByOne:add(nn.Linear(nOutputsDense,1))

	splitter:add(all)
	splitter:add(oneByOne)
	model:add(splitter)
	model:add(nn.JoinTable(1))
	model:add(nn.Sigmoid())

        layers.init(model)

        if opt.cudnn == 'deterministic' then
           model:apply(function(m)
              if m.setMode then m:setMode(1,1,1) end
           end)
        end

        model:get(1).gradInput = nil

        return model
end

return models 
