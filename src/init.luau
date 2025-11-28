
--[=[
	@class ReplicatedInstanceId
	
	Roblox Instance에 uint32 식별자를 부여하고 서버·클라이언트 간에 참조를 동기화하는 도구입니다.
	Buffer 직렬화나 원격 호출에서 Instance를 안전하게 전달할 때 사용합니다.
]=]

local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")

local Promise = require("../roblox_packages/Promise")
local base91 = require("../roblox_packages/base91")

local REPLICATED_INSTANCE_TAG = "RI"
local ID_TAG_PREFIX = "RI_"
local IS_CLIENT = RunService:IsClient()

local ReplicatedInstanceId = {}
ReplicatedInstanceId.__type = "ReplicatedInstanceId"

local replicatedIdsByInstance = {} :: {[Instance]: number}
local instancesByReplicatedId = {} :: {[number]: Instance}

local function cleanupInstance(instance: Instance)
	local id = replicatedIdsByInstance[instance]
	if id then
		replicatedIdsByInstance[instance] = nil
		instancesByReplicatedId[id] = nil
	end
end

local cacheTagNamesById = {} :: {[number]: string}
local function getTagNameFromId(id: number): string
	local tagName = cacheTagNamesById[id] 
	if tagName then
		return tagName
	end
	tagName = ID_TAG_PREFIX .. base91.encodeString(string.pack("I4", id))
	cacheTagNamesById[id] = tagName
	return tagName
end

local function observeInstanceWithId(instance: Instance, id: number)
	local conn
	conn = CollectionService:GetInstanceRemovedSignal(getTagNameFromId(id)):Connect(function(removedInstance)
		if removedInstance == instance then
			cleanupInstance(instance)
			conn:Disconnect()
		end
	end)
end

--#region Functions
local function getAndRegisterInstanceIdFromTags(instance: Instance): number
	for _, tag in instance:GetTags() do
		if tag:sub(1, 3) == ID_TAG_PREFIX then
			local raw = tag:sub(4)
			local success, unpackedId = pcall(function()
				return string.unpack("I4", base91.decodeString(raw))
			end)

			if success then
				replicatedIdsByInstance[instance] = unpackedId
				instancesByReplicatedId[unpackedId] = instance
				observeInstanceWithId(instance, unpackedId)
				return unpackedId
			end
		end
	end
	
	return error(`Failed To Find Id From Instance "{instance}".`)
end

--[=[
	@within ReplicatedInstanceId
	@function GetId
	지정한 Instance에 할당된 복제 ID를 반환합니다.
	@param instance Instance -- ID를 조회할 객체.
	@return number -- 기존에 부여된 uint32 ID.
]=]
function ReplicatedInstanceId.GetId(instance: Instance): number
	local id = ReplicatedInstanceId.FindId(instance)
	return id or error(`Instance "{instance}" does not have a ReplicatedId.`)
end

--[=[
	@within ReplicatedInstanceId
	@function FindId
	이미 기록된 복제 ID가 있으면 반환하고, 없으면 nil을 반환합니다.
	@param instance Instance
	@return number? -- 존재하면 uint32 ID.
]=]
function ReplicatedInstanceId.FindId(instance: Instance): number?
	local id = replicatedIdsByInstance[instance]
	if id then 
		return id 
	end
	
	if IS_CLIENT then
		-- 인스턴스가 복제되고, 즉시 Id를 구하려고 했다면
		-- 아래 로드 함수가 작동되기 전, 캐시테이블에 저장되기 전일 수 있음으로,
		-- Tag 로부터 Id를 즉시 구해야합니다.
		return getAndRegisterInstanceIdFromTags(instance)
	end
	
	return nil
end

--[=[
	@within ReplicatedInstanceId
	@function FindInstanceFromId
	등록된 ID에서 Instance를 찾습니다.
	@param id number -- uint32 복제 ID.
	@return Instance? -- 캐시에 있으면 해당 Instance.
]=]
function ReplicatedInstanceId.FindInstanceFromId(id: number): Instance?
	local instance = instancesByReplicatedId[id]
	if instance then
		return instance
	end

	if IS_CLIENT then
		-- 인스턴스가 복제되고, 즉시 Id를 구하려고 했다면
		-- 아래 로드 함수가 작동되기 전, 캐시테이블에 저장되기 전일 수 있음으로,
		-- GetTagged 로 즉시 구해야합니다.
		return CollectionService:GetTagged( getTagNameFromId(id) )[1]
	end

	return nil
end

--[=[
	@within ReplicatedInstanceId
	@function GetInstanceFromId
	지정한 ID와 연결된 Instance를 반환하거나 없으면 오류를 발생시킵니다.
	@param id number -- uint32 복제 ID.
	@return Instance -- 대응하는 Instance.
]=]
function ReplicatedInstanceId.GetInstanceFromId(id: number): Instance
return ReplicatedInstanceId.FindInstanceFromId(id) or error(`No instance found for replicatedId {id}.`)
end

--[=[
	@within ReplicatedInstanceId
	@function WaitForInstanceFromId
	컬렉션 서비스에서 ID를 가진 Instance가 나타날 때까지 기다립니다.
	@param id number -- uint32 복제 ID.
	@param timeout number? -- 초 단위 제한, 기본값은 무제한.
	@return Instance -- 발견된 Instance.
]=]
function ReplicatedInstanceId.WaitForInstanceFromId(id: number, timeout: number?): Instance
	local instance = ReplicatedInstanceId.FindInstanceFromId(id)
	if instance then
		return instance
	end
	
	if timeout then
		local suc
		suc, instance = Promise.fromEvent(
			CollectionService:GetInstanceAddedSignal( getTagNameFromId(id) )
		):timeout(timeout):await()
		return if suc 
			then instance
			else nil
	end

	instance = CollectionService:GetInstanceAddedSignal( getTagNameFromId(id) ):Wait()
	
	return instance
end

--#region Server Functions
local idRandomGenerator = Random.new()

--[=[
	@within ReplicatedInstanceId
	@function AssignId
	서버에서 새 uint32 복제 ID를 생성해 Instance에 부여합니다.
	@param instance Instance -- ID를 부여할 객체.
	@return number -- 새로 할당된 ID.
]=]
function ReplicatedInstanceId.AssignId(instance: Instance): number
	if IS_CLIENT then
		error("Cannot create replicated id on client")
	end
	
	if replicatedIdsByInstance[instance] then
		error(`Instance "{instance}" already has a ReplicatedId.`)
	end

	local newId
	repeat
		newId = idRandomGenerator:NextInteger(1, 2^32 - 1)
	until not instancesByReplicatedId[newId]

	replicatedIdsByInstance[instance] = newId
	instancesByReplicatedId[newId] = instance

	local tag = getTagNameFromId(newId)
	CollectionService:AddTag(instance, tag)
	CollectionService:AddTag(instance, REPLICATED_INSTANCE_TAG)

	observeInstanceWithId(instance, newId)

	return newId
end

--[=[
	@within ReplicatedInstanceId
	@function FindOrAssignId
	이미 ID가 있으면 재사용하고, 없으면 AssignId를 호출해 새 ID를 반환합니다.
	@param instance Instance -- 대상 객체.
	@return number -- 기존 또는 새 ID.
]=]
function ReplicatedInstanceId.FindOrAssignId(instance: Instance): number
	return 
		ReplicatedInstanceId.FindId(instance)
		or ReplicatedInstanceId.AssignId(instance)
end

--#region Load

-- 기존 인스턴스들을 로드합니다.
for _, instance in CollectionService:GetTagged(REPLICATED_INSTANCE_TAG) do
	local id = getAndRegisterInstanceIdFromTags(instance)
	
	replicatedIdsByInstance[instance] = id
	instancesByReplicatedId[id] = instance
	observeInstanceWithId(instance, id)
end

if IS_CLIENT then
	CollectionService:GetInstanceAddedSignal(REPLICATED_INSTANCE_TAG):Connect(function(instance)
		local id = getAndRegisterInstanceIdFromTags(instance)

		replicatedIdsByInstance[instance] = id
		instancesByReplicatedId[id] = instance
		observeInstanceWithId(instance, id)
	end)
end



return ReplicatedInstanceId