shader_type spatial;

// Dropdown for the inspector
uniform int channel_to_display : hint_enum(
	"Layer 1 (COLOR)",
	"Layer 2 (CUSTOM0)",
	"Layer 3 (CUSTOM1)",
	"Layer 4 (CUSTOM2)"
) = 0;

// Varyings: pass-through variables from vertex to fragment shader
varying vec4 data_layer_1; // COLOR
varying vec4 data_layer_2; // CUSTOM0
varying vec4 data_layer_3; // CUSTOM1
varying vec4 data_layer_4; // CUSTOM2

void vertex() {
	// Read mesh data in vertex shader (only place where CUSTOMx exists).
	data_layer_1 = COLOR;   
	data_layer_2 = CUSTOM0; 
	data_layer_3 = CUSTOM1; 
	data_layer_4 = CUSTOM2;
}

void fragment() {
	METALLIC = 0.0;
	ROUGHNESS = 1.0;
	
	vec4 final_color = vec4(0.0);
	
	// Read varying variables in fragment shader
	if (channel_to_display == 0) {
		final_color = data_layer_1;
	} else if (channel_to_display == 1) {
		final_color = data_layer_2;
	} else if (channel_to_display == 2) {
		final_color = data_layer_3;
	} else if (channel_to_display == 3) {
		final_color = data_layer_4;
	}
	
	ALBEDO = final_color.rgb;
}