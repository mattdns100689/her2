csv = require "csv"
require "paths"
local models = require "models"
local filterModel = torch.load("filter/filter.model"):cuda()

loadData = {}

function loadData.init(tid,nThreads,level)

	local dataPath
	if params.test == 0 then 
		print("==> Training")
		csvFile = "groundTruthTrain.csv"
		dataPath = "data/"
	elseif params.test == 1 and params.actualTest ==0 then
		print("==> Testing")
		csvFile = "groundTruthTest.csv"
		dataPath = "data/"
	else	
		print("==> True test")
		csvFile = "groundTruth.csv"
		dataPath = "testData/"
	end
	local HEorHER2
	if params.HEorHER2 == 1 then	
		HEorHER2 = "HE/"
	else
		HEorHER2 = "HER2/"
	end

	local groundTruth = csv.csvToTable(dataPath .. csvFile) -- main truth table
	allPaths = {}
	local nObs = csv.length(groundTruth)
	local obs = 1
	for i = tid, nObs, nThreads do 

	        local row = groundTruth[i]:split(",")
	        local caseNumber, score, percScore = row[1], row[2], row[3]
	        local casePath = dataPath .. "roi_" .. caseNumber .. "/" .. level .."/" .. HEorHER2

	        local imgPaths = {} 
	        j = 1
	        for f in paths.files(casePath,".jpg") do
			 imgPaths[j] = casePath .. f
			 j = j + 1
	        end
	        allPaths[obs] = {imgPaths,score,percScore,caseNumber}
		obs = obs + 1
	 end 
	 collectgarbage()
end

function loadData.augmentCrop(img,windowSize)
	assert(windowSize<img:size(3),string.format("Window size %d is bigger than image size of %d.",
		windowSize,img:size(3)))
	-- Random  flips
	local randInt = torch.random(4)
	if randInt == 1 then	
	elseif randInt == 2 then
		image.vflip(img,img)
	elseif randInt == 3 then
		image.hflip(img,img)
	elseif randInt == 4 then
		image.vflip(img,img)
		image.hflip(img,img)
	end


	maxX = img:size(3) - windowSize
	maxY = img:size(2) - windowSize

	--- Try scaling ---
	
	return img:narrow(2,torch.random(maxY),windowSize):narrow(3,torch.random(maxX),windowSize) --cropped 
end

function loadData.loadXY(nWindows,windowSize)

	if params.test == 0 then

		-- Train
		currentTable = allPaths[torch.random(#allPaths)] -- Train is stochastic
	else
		-- Test
		if currentObs == nil then 
			currentObs = 1 
			nEpochs = 1
		elseif currentObs == #allPaths then 
			currentObs = 1
			nEpochs = nEpochs + 1
		else 
			currentObs = currentObs + 1	
		end
		currentTable = allPaths[currentObs] --Test is deterministic
	end

	local nObsT = csv.length(currentTable[1])


	local Xy = {}

	local tensors = {}
	local imgDim
	for i = 1, nWindows do
		 local suitablePic = false
		 local img
		 while suitablePic == false do 

			 local imgPath = currentTable[1][torch.random(nObsT)] -- Draw random int to select window 
			 img = image.loadJPG(imgPath)
			 imgDim = img:size(3)
			 img = loadData.augmentCrop(img, windowSize)
			 local imgScale = image.scale(img,128,128,"simple"):cuda()
			 local output = filterModel:forward(imgScale:view(1,3,128,128))
			 if output[1] > 0.9 then suitablePic = true end

		end
		tensors[i] = img:reshape(1,3,windowSize,windowSize)
	end

	Xy["data"] =  torch.cat(tensors,1):cuda()
	Xy["score"] = currentTable[2]/3 
	Xy["percScore"] = currentTable[3]/100 -- Normalize
	Xy["caseNo"] = currentTable[4] 
	Xy["coverage"] = params.nWindows*(torch.pow(params.windowSize,2)/torch.pow(imgDim,2))/#currentTable[1]

	local target = torch.zeros(params.nWindows + 1,2)
	target[{{},{1}}]:fill(Xy["score"])
	target[{{},{2}}]:fill(Xy["percScore"])
	target = target:cuda()
	Xy["target"] = target

	collectgarbage()
	return Xy 
end

function loadData.main(display,viewAug)
	require "cunn"

	params = {}
	params.windowSize = 100
	if viewAug == 1 then 
		params.nWindows = 1
	else 
		params.nWindows = 5 
	end

	params.level = 3 
	params.nFeats = 16
	params.nLayers = 6 
	params.test = 0
	params.nTestPreds = 10

	model = models.model1()

	if init == nil then
		require "image"
		loadData.init(1,1,params.level)
		init = "Not nil"
	end

	Xy = loadData.loadXY(params.nWindows,params.windowSize)
	print(Xy)
	if display == 1 then
		initPic = torch.range(1,torch.pow(params.windowSize,2),1):reshape(params.windowSize,params.windowSize)
		imgDisplay = image.display{image=initPic, zoom=2, offscreen=false}
		image.display{image = Xy["data"], win = imgDisplay, legend = "Score = ".. Xy["score"].. ". Case number = " .. Xy["caseNo"]}
	end

	if viewAug == 1 then
		initPic = torch.range(1,torch.pow(params.windowSize,2),1):reshape(params.windowSize,params.windowSize)
		imgDisplay = image.display{image=initPic, zoom=1, offscreen=false}
		imgsPath = allPaths[torch.random(#allPaths)][1]
		imgPath = imgsPath[torch.random(#imgsPath)]
		print(imgPath)
		for i = 1, 10 do
			img = image.loadJPG(imgPath)
		 	img = loadData.augmentCrop(img, params.windowSize)
			image.display{image = img, win = imgDisplay, legend = "Score = ".. Xy["score"].. ". Case number = " .. Xy["caseNo"]}
		end
	end


end


return loadData
