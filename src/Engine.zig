const std = @import("std");
const vk = @import("vulkan-zig");
const vkk = @import("vk-kickstart");
const c = @import("c.zig");
const Window = @import("Window.zig");

const assert = std.debug.assert;

const vki = vkk.dispatch.vki;
const vkd = vkk.dispatch.vkd;

window: *Window,
surface: vk.SurfaceKHR,
instance: vkk.Instance,
physical_device: vkk.PhysicalDevice,
device: vkk.Device,
swapchain: vkk.Swapchain,
swapchain_images: []vk.Image,
swapchain_image_views: []vk.ImageView,

pub fn init(allocator: std.mem.Allocator, window: *Window) !@This() {
    const instance = try vkk.Instance.create(c.glfwGetInstanceProcAddress, .{
        .app_name = "ft_vox",
        .app_version = 1,
        .engine_name = "engine",
        .engine_version = 1,
        .required_api_version = vk.API_VERSION_1_1,
    });
    errdefer instance.destroy();

    const surface = try window.createSurface(instance.handle);
    errdefer vki().destroySurfaceKHR(instance.handle, surface, null);

    const physical_device = try vkk.PhysicalDevice.select(&instance, .{
        .surface = surface,
        .preferred_type = .discrete_gpu,
    });

    const device = try vkk.Device.create(&physical_device, null, null);
    errdefer device.destroy();

    const swapchain = try vkk.Swapchain.create(&device, surface, .{
        .desired_extent = window.extent(),
        .desired_formats = &.{
            .{ .format = .b8g8r8a8_unorm, .color_space = .srgb_nonlinear_khr },
        },
        .desired_present_modes = &.{
            .fifo_khr,
        },
    });
    errdefer swapchain.destroy();

    const images = try allocator.alloc(vk.Image, swapchain.image_count);
    try swapchain.getImages(images);

    const image_views = try allocator.alloc(vk.ImageView, images.len);
    try swapchain.getImageViews(images, image_views);

    return .{
        .window = window,
        .surface = surface,
        .instance = instance,
        .physical_device = physical_device,
        .device = device,
        .swapchain = swapchain,
        .swapchain_images = images,
        .swapchain_image_views = image_views,
    };
}

pub fn deinit(self: *@This()) void {
    destroyImageViews(self.device.handle, self.swapchain_image_views);
    self.swapchain.destroy();
    self.device.destroy();
    vki().destroySurfaceKHR(self.instance.handle, self.surface, null);
    self.instance.destroy();
    self.window.deinit();
}

pub fn run(self: *@This()) !void {
    _ = self;
}

fn destroyImageViews(device: vk.Device, image_views: []vk.ImageView) void {
    assert(device != .null_handle);

    for (image_views) |view| {
        assert(view != .null_handle);
        vkd().destroyImageView(device, view, null);
    }
}
