const vk = @import("vulkan-zig");

pub const device = vk.DeviceCommandFlags{
    .destroyDevice = true,
    .getDeviceQueue = true,
    .createSwapchainKHR = true,
    .destroySwapchainKHR = true,
    .getSwapchainImagesKHR = true,
    .createImageView = true,
    .destroyImageView = true,
    .createRenderPass = true,
    .destroyRenderPass = true,
    .createFramebuffer = true,
    .destroyFramebuffer = true,
    .createImage = true,
    .destroyImage = true,
    .createBuffer = true,
    .destroyBuffer = true,
    .createSemaphore = true,
    .destroySemaphore = true,
    .createFence = true,
    .destroyFence = true,
    .resetFences = true,
    .createShaderModule = true,
    .destroyShaderModule = true,
    .createDescriptorPool = true,
    .destroyDescriptorPool = true,
    .createDescriptorSetLayout = true,
    .destroyDescriptorSetLayout = true,
    .allocateDescriptorSets = true,
    .updateDescriptorSets = true,
    .createPipelineLayout = true,
    .destroyPipelineLayout = true,
    .createGraphicsPipelines = true,
    .destroyPipeline = true,
    .createSampler = true,
    .destroySampler = true,
    .createCommandPool = true,
    .destroyCommandPool = true,
    .resetCommandPool = true,
    .allocateCommandBuffers = true,
    .allocateMemory = true,
    .freeMemory = true,
    .mapMemory = true,
    .unmapMemory = true,
    .bindImageMemory = true,
    .bindBufferMemory = true,
    .beginCommandBuffer = true,
    .waitForFences = true,
    .deviceWaitIdle = true,
    .getImageMemoryRequirements = true,
    .getBufferMemoryRequirements = true,
    .acquireNextImageKHR = true,
    .queueSubmit = true,
    .queuePresentKHR = true,
    .endCommandBuffer = true,
    .cmdBeginRenderPass = true,
    .cmdSetViewport = true,
    .cmdSetScissor = true,
    .cmdBindPipeline = true,
    .cmdDraw = true,
    .cmdEndRenderPass = true,
    .cmdCopyBuffer = true,
    .cmdBindVertexBuffers = true,
    .cmdBindDescriptorSets = true,
    .cmdPushConstants = true,
    .cmdPipelineBarrier = true,
    .cmdCopyBufferToImage = true,
};
