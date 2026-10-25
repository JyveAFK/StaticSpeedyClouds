#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

#include "./cloud_common.comp"
#include "./cloud_composite.comp"
