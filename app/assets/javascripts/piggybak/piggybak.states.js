var geodata;
var order_type;
var order_type_payment;
var form_name;
if (typeof is_subscription !== 'undefined') {
  order_type = 'subscription_';
  order_type_payment = 'subscription_order_';
  form_name = '_subscription';
}
else {
  order_type = '';
  order_type_payment = '';
  form_name = '';
}

var piggybak_states = {
	initialize_listeners: function() {
		$('#order_' + order_type + 'shipping_address_attributes_country_id').change(function() {
			piggybak_states.update_state_option('shipping');
		});
		$('#order_' + order_type + 'billing_address_attributes_country_id').change(function() {
			piggybak_states.update_state_option('billing');
		});
		return;
	},
	populate_geodata: function() {
		$.ajax({
			url: geodata_lookup,
			cached: false,
			dataType: "JSON",
			success: function(data) {
				geodata = data;
				piggybak_states.update_state_option('shipping');
				piggybak_states.update_state_option('billing');
			}
		});
	},
	update_state_option: function(type, block) {
		var country_field = $('#order_' + order_type + type + '_address_attributes_country_id');
		var country_id = country_field.val();
		var new_field;

		if(geodata.countries["country_" + country_id].length > 0) {
			new_field = $('<select>');
			$.each(geodata.countries["country_" + country_id], function(i, j) {
				new_field.append($('<option>').val(j.id).html(j.name));
			});	
		} else {
			new_field = $('<input>');
		}
		var old_field = $('#order_' + order_type +  type + '_address_attributes_state_id');
		new_field.attr('name', old_field.attr('name')).attr('id', old_field.attr('id'));
		if(old_field.prop('tagName') == new_field.prop('tagName')) {
			new_field.val(old_field.val());
		}
		old_field.replaceWith(new_field);

		if(block) {
			block();
		}
		return;
	}
};

$(function() {
	if($('form#new_order' + form_name).size() == 0) {
		return;
	}
	piggybak_states.populate_geodata();
	piggybak_states.initialize_listeners();
});

